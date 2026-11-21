open Assemble_plan

type runner =
  Process.output -> string list -> (Process.result, Process.error) result

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string

type error = { cause : cause; completed : string list }

type outcome = {
  image_id : string;
  container_id : string;
  created : bool;
  started : bool;
}

let compatibility = Container_runtime.compatibility

let run ?execute ?read_many
    ?(probe = fun () -> Container_runtime.local_selinux ()) loaded =
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
  let image : Podman.image option ref = ref None in
  let container : Podman.container option ref = ref None in
  let built = ref false and created = ref false and started = ref false in
  let ready () =
    let* () =
      match !image with None -> Ok () | Some i -> own_image i.Podman.labels
    in
    let* () =
      match !container with
      | None -> Ok ()
      | Some c -> own_container c.Podman.labels
    in
    match (!image, !container) with
    | None, Some _ ->
        fail (Conflict "Existing container has no configured image")
    | Some i, Some c ->
        let* () = check i c in
        if Container_runtime.supported_state c.state then Ok ()
        else fail (Conflict "Unsupported container state")
    | _ -> Ok ()
  in
  let id_image () = match !image with Some i -> i.Podman.id | None -> "" in
  let id_container () =
    match !container with Some c -> c.Podman.id | None -> ""
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
         let commands =
           List.filter_map
             (fun (step : Assemble_plan.step) ->
               if List.mem step.operation [ Image_inspect; Container_inspect ]
               then
                 Some
                   (Assemble_plan.resolve ~image_id:"" ~container_id:""
                      step.command)
               else None)
             plan.steps
         in
         prefetched := List.combine commands (read_many commands));
      Ok ())
  in
  (* Re-inspect the container after creating or starting it. *)
  let inspect_after_mutation ~running argv =
    let* c = Result.bind (inspect_container ~initial:false argv) present in
    let* () =
      if c.Podman.id <> id_container () then
        fail (Conflict "Container ID differs")
      else Ok ()
    in
    let* () = match !image with Some i -> check i c | None -> Ok () in
    container := Some c;
    if running && c.state <> "running" then
      fail (Runtime "Container is not running after start")
    else Ok ()
  in
  let rec loop = function
    | [] -> Ok ()
    | (step : Assemble_plan.step) :: rest ->
        let argv () =
          Assemble_plan.resolve ~image_id:(id_image ())
            ~container_id:(id_container ()) step.command
        in
        let* () =
          match step.operation with
          | Availability -> availability (argv ())
          | Image_inspect ->
              let* i = inspect_image ~initial:true (argv ()) in
              image := i;
              Ok ()
          | Container_inspect -> (
              let* c = inspect_container ~initial:true (argv ()) in
              match c with
              | None -> Ok ()
              | Some c ->
                  let* () =
                    match !image with Some i -> check i c | None -> Ok ()
                  in
                  container := Some c;
                  Ok ())
          | Build ->
              let* () = ready () in
              if !image <> None then Ok ()
              else
                let* _ = mutation Process.Inherit (argv ()) in
                built := true;
                Ok ()
          | Built_inspect ->
              if not !built then Ok ()
              else
                let* i =
                  Result.bind (inspect_image ~initial:false (argv ())) present
                in
                image := Some i;
                Ok ()
          | Create ->
              if !container <> None then Ok ()
              else
                let* r = mutation Process.Capture (argv ()) in
                let* id = created_id r in
                created := true;
                container :=
                  Some
                    {
                      Podman.id;
                      labels = [];
                      state = "created";
                      image_id = id_image ();
                      user = "";
                      userns = "";
                      workdir = "";
                      init = false;
                      mounts = [];
                      created = None;
                    };
                Ok ()
          | Created_inspect ->
              if !created then inspect_after_mutation ~running:false (argv ())
              else Ok ()
          | Start -> (
              match !container with
              | Some c when c.state <> "running" ->
                  let* _ = mutation Process.Capture (argv ()) in
                  started := true;
                  Ok ()
              | _ -> Ok ())
          | Started_inspect ->
              if !started then inspect_after_mutation ~running:true (argv ())
              else Ok ()
        in
        loop rest
  in
  let* () = loop plan.steps in
  Ok
    {
      image_id = id_image ();
      container_id = id_container ();
      created = !created;
      started = !started;
    }
