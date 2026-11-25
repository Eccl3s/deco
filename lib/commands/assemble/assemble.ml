open Assemble_plan

type runner =
  Process.output -> string list -> (Process.result, Process.error) result

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Hook of Hook.failure

type error = { cause : cause; completed : string list }

type outcome = {
  image_id : string;
  container_id : string;
  created : bool;
  started : bool;
}

let compatibility = Container_runtime.compatibility

let run ?execute ?read_many
    ?(probe = fun () -> Container_runtime.local_selinux ()) ?hook
    ?(on_ready = fun (_ : outcome) -> Ok ()) loaded =
  let concurrent = Option.is_some read_many || Option.is_none execute in
  let injected = execute in
  let execute =
    Option.value ~default:(fun output argv -> Process.run ~output argv) execute
  in
  let read_many =
    match (read_many, injected) with
    | Some batch, _ -> batch
    | None, Some _ -> List.map (execute Process.Capture)
    | None, None -> fun commands -> Process.run_many commands
  in
  let prefetched = ref [] in
  let completed = ref [] in
  let fail cause = Error { cause; completed = List.rev !completed } in
  let ( let* ) result f =
    match result with Ok x -> f x | Error e -> Error e
  in
  let read argv =
    match List.assoc_opt argv !prefetched with
    | Some r ->
        prefetched := List.remove_assoc argv !prefetched;
        r
    | None -> execute Process.Capture argv
  in
  let selinux = Container_runtime.make_selinux_resolver ~run:read ~probe () in
  let check image container =
    match
      Container_runtime.check_compatibility ~selinux loaded image container
    with
    | Ok () -> Ok ()
    | Error (Container_runtime.Conflict e) -> fail (Conflict e)
    | Error (Container_runtime.Podman e) -> fail (Podman e)
  in
  let mutation output argv =
    match execute output argv with
    | Error e -> fail (Runtime (e.operation ^ ": " ^ e.message))
    | Ok r -> (
        match r.status with
        | Unix.WEXITED 0 ->
            completed :=
              String.concat " " (List.filteri (fun i _ -> i < 3) argv)
              :: !completed;
            Ok r
        | _ -> fail (Runtime (Podman.message r)))
  in
  let* plan =
    match Assemble_plan.make loaded with
    | Ok p -> Ok p
    | Error e -> fail (Planning e)
  in
  let own resource labels =
    match Container_runtime.verify_ownership loaded resource labels with
    | Ok () -> Ok ()
    | Error (Container_runtime.Conflict e) -> fail (Conflict e)
    | Error (Container_runtime.Podman e) -> fail (Podman e)
  in
  (* The container is named by its configured name even in the steps that
     inspect it by ID: those inspect the container assemble just created under
     that name, and the name is what a recovery hint should show. *)
  let own_image = own (Container_runtime.Image plan.Assemble_plan.image_name)
  and own_container =
    own
      (Container_runtime.Container loaded.Config_loader.effective.container.name)
  in
  (* The planned command for [operation] with its placeholders resolved. The
     plan holds every operation exactly once, so the lookup cannot fail. *)
  let command ?(image_id = "") ?(container_id = "") operation =
    let step =
      List.find
        (fun (step : Assemble_plan.step) -> step.operation = operation)
        plan.steps
    in
    Assemble_plan.resolve ~image_id ~container_id step.command
  in
  (* Before any mutation, the resources found must fit together. Ownership was
     already verified when each one was inspected. *)
  let ready image container =
    match (image, container) with
    | None, Some _ ->
        fail (Conflict "Existing container has no configured image")
    | Some i, Some (c : Podman.container) ->
        let* () = check i c in
        if Container_runtime.supported_state c.state then Ok ()
        else fail (Conflict "Unsupported container state")
    | _ -> Ok ()
  in
  (* A failed read is ambiguous before anything has changed: Podman itself may
     be down. After a mutation it is reported as it is. *)
  let read_failure ~initial message =
    if initial then
      match Podman.info ~run:read () with
      | Error e -> fail (Podman e)
      | Ok _ -> fail (Runtime message)
    else fail (Runtime message)
  in
  (* Inspect with a planned command. [Ok None] means the resource is absent;
     a non-zero inspect falls back to an existence check to tell absence from
     failure. Ownership is verified for every resource found. *)
  let inspect ~initial ~operation ~decode ~lookup ~owned argv =
    let* r =
      match read argv with
      | Ok r -> Ok r
      | Error e -> read_failure ~initial (e.Process.operation ^ ": " ^ e.message)
    in
    if r.Process.status = Unix.WEXITED 0 then
      let* x =
        match decode r.stdout with
        | Ok x -> Ok x
        | Error message ->
            fail (Podman (Invalid_response { operation; message }))
      in
      let* () = owned x in
      Ok (Some x)
    else
      let name = List.hd (List.rev argv) in
      let run command = if command = argv then Ok r else read command in
      match lookup ~run name with
      | Ok Podman.Absent -> Ok None
      (* Not expected: the lookup replays this failed inspection. *)
      | Ok (Podman.Present _) ->
          read_failure ~initial "Resource missing after mutation"
      | Error (Podman.Runtime { message; _ }) -> read_failure ~initial message
      | Error e -> fail (Podman e)
  in
  let inspect_image ~initial =
    inspect ~initial ~operation:"image inspect" ~decode:Podman.decode_image
      ~lookup:(fun ~run name -> Podman.inspect_image ~run name)
      ~owned:(fun (i : Podman.image) -> own_image i.labels)
  in
  let inspect_container ~initial =
    inspect ~initial ~operation:"container inspect"
      ~decode:Podman.decode_container
      ~lookup:(fun ~run name -> Podman.inspect_container ~run name)
      ~owned:(fun (c : Podman.container) -> own_container c.labels)
  in
  (* Only the initial inspections may find a resource absent. *)
  let present = function
    | Some x -> Ok x
    | None -> fail (Runtime "Resource missing after mutation")
  in
  let created_id (r : Process.result) =
    let id = String.trim r.stdout in
    if
      String.length id = 64
      && String.for_all
           (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
           id
    then Ok id
    else fail (Runtime "Invalid created container ID")
  in
  let availability argv =
    let* r =
      match read argv with
      | Ok r -> Ok r
      | Error e -> fail (Podman (Podman.unavailable e))
    in
    if r.status <> Unix.WEXITED 0 then
      fail (Podman (Unavailable (Podman.message r)))
    else (
      (if concurrent then
         let commands = [ command Image_inspect; command Container_inspect ] in
         prefetched := List.combine commands (read_many commands));
      Ok ())
  in
  (* Re-inspect the container after creating or starting it: it must still be
     the same container, owned and compatible with the image. *)
  let inspect_after_mutation ~image ~id ~running argv =
    let* c = Result.bind (inspect_container ~initial:false argv) present in
    let* () =
      if c.Podman.id <> id then fail (Conflict "Container ID differs")
      else Ok ()
    in
    let* () = check image c in
    if running && c.state <> "running" then
      fail (Runtime "Container is not running after start")
    else Ok c
  in
  let ensure_image = function
    | Some image -> Ok image
    | None ->
        let* _ = mutation Process.Inherit (command Build) in
        Result.bind
          (inspect_image ~initial:false (command Built_inspect))
          present
  in
  (* Returns the container and whether it was created. *)
  let ensure_container (image : Podman.image) = function
    | Some container -> Ok (container, false)
    | None ->
        (* Podman would create the container without capabilities the image's
           label excludes; refuse before creating anything. *)
        let* () =
          match Container_runtime.unapplied_capabilities loaded image with
          | None -> Ok ()
          | Some message -> fail (Conflict message)
        in
        let* r = mutation Process.Capture (command ~image_id:image.id Create) in
        let* id = created_id r in
        let* container =
          inspect_after_mutation ~image ~id ~running:false
            (command ~container_id:id Created_inspect)
        in
        Ok (container, true)
  in
  (* Returns the container and whether it was started. *)
  let ensure_running image (container : Podman.container) =
    if container.state = "running" then Ok (container, false)
    else
      let id = container.id in
      let* _ = mutation Process.Capture (command ~container_id:id Start) in
      let* container =
        inspect_after_mutation ~image ~id ~running:true
          (command ~container_id:id Started_inspect)
      in
      Ok (container, true)
  in
  let* () = availability (command Availability) in
  let* image = inspect_image ~initial:true (command Image_inspect) in
  let* container =
    inspect_container ~initial:true (command Container_inspect)
  in
  let* () = ready image container in
  let* image = ensure_image image in
  (* A container that an earlier run created but never started still owes
     post_create. *)
  let fresh =
    match container with
    | Some (c : Podman.container) -> Container_runtime.never_started c.state
    | None -> true
  in
  let* container, created = ensure_container image container in
  let* container, started = ensure_running image container in
  let outcome =
    { image_id = image.id; container_id = container.id; created; started }
  in
  let* () =
    match on_ready outcome with Ok () -> Ok () | Error cause -> fail cause
  in
  (* Hooks run in the verified running container: post_create on its first
     start, then post_start after any start. *)
  let run_hook name =
    match Hook.run ?run:hook loaded ~container_id:container.id name with
    | Ok () -> Ok ()
    | Error failure -> fail (Hook failure)
  in
  let* () = if fresh then run_hook Hook.Post_create else Ok () in
  let* () = if started then run_hook Hook.Post_start else Ok () in
  Ok outcome
