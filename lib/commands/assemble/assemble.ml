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
  let rec loop = function
    | [] -> Ok ()
    | (step : Assemble_plan.step) :: rest ->
        let index = step.operation in
        let read_failure message =
          if List.mem index [ Image_inspect; Container_inspect ] then
            match Podman.info ~run:read () with
            | Error e -> fail (Podman e)
            | Ok _ -> fail (Runtime message)
          else fail (Runtime message)
        in
        let* () = if index = Build then ready () else Ok () in
        let active =
          match index with
          | Availability | Image_inspect | Container_inspect -> true
          | Build -> !image = None
          | Built_inspect -> !built
          | Create -> !container = None
          | Created_inspect -> !created
          | Start -> (
              match !container with
              | Some c -> c.state <> "running"
              | None -> false)
          | Started_inspect -> !started
        in
        let* () =
          if not active then Ok ()
          else
            let argv =
              Assemble_plan.resolve ~image_id:(id_image ())
                ~container_id:(id_container ()) step.command
            in
            let mutating = List.mem index [ Build; Create; Start ] in
            let* r =
              if mutating then
                mutation
                  (if index = Build then Process.Inherit else Capture)
                  argv
              else
                match read argv with
                | Error e ->
                    if index = Availability then
                      fail (Podman (Podman.unavailable e))
                    else read_failure (e.operation ^ ": " ^ e.message)
                | Ok r -> Ok r
            in
            let success = r.Process.status = Unix.WEXITED 0 in
            let absent = ref false in
            let inspecting =
              List.mem index
                [
                  Image_inspect;
                  Container_inspect;
                  Built_inspect;
                  Created_inspect;
                  Started_inspect;
                ]
            in
            let* () =
              if inspecting && not success then
                let kind =
                  if List.mem index [ Image_inspect; Built_inspect ] then
                    "image"
                  else "container"
                in
                let name = List.hd (List.rev argv) in
                let run command =
                  if command = argv then Ok r else read command
                in
                let result =
                  if kind = "image" then
                    Result.map
                      (function Podman.Absent -> true | Present _ -> false)
                      (Podman.inspect_image ~run name)
                  else
                    Result.map
                      (function Podman.Absent -> true | Present _ -> false)
                      (Podman.inspect_container ~run name)
                in
                match result with
                | Ok true
                  when List.mem index [ Image_inspect; Container_inspect ] ->
                    absent := true;
                    Ok ()
                | Ok _ -> read_failure "Resource missing after mutation"
                | Error (Podman.Runtime { message; _ }) -> read_failure message
                | Error e -> fail (Podman e)
              else Ok ()
            in
            if !absent then Ok ()
            else if not success then
              if index = Availability then
                fail (Podman (Unavailable (Podman.message r)))
              else read_failure (Podman.message r)
            else
              match index with
              | Image_inspect | Built_inspect ->
                  let* i =
                    match Podman.decode_image r.stdout with
                    | Ok i -> Ok i
                    | Error e ->
                        fail
                          (Podman
                             (Invalid_response
                                { operation = "image inspect"; message = e }))
                  in
                  let* () = own_image i.labels in
                  image := Some i;
                  Ok ()
              | Container_inspect | Created_inspect | Started_inspect ->
                  let* c =
                    match Podman.decode_container r.stdout with
                    | Ok c -> Ok c
                    | Error e ->
                        fail
                          (Podman
                             (Invalid_response
                                { operation = "container inspect"; message = e }))
                  in
                  let* () = own_container c.labels in
                  let* () =
                    if index <> Container_inspect && c.id <> id_container ()
                    then fail (Conflict "Container ID differs")
                    else Ok ()
                  in
                  let* () =
                    match !image with Some i -> check i c | None -> Ok ()
                  in
                  container := Some c;
                  if index = Started_inspect && c.state <> "running" then
                    fail (Runtime "Container is not running after start")
                  else Ok ()
              | Availability ->
                  let commands =
                    List.filter_map
                      (fun step ->
                        if
                          List.mem step.operation
                            [ Image_inspect; Container_inspect ]
                        then
                          Some
                            (Assemble_plan.resolve ~image_id:"" ~container_id:""
                               step.command)
                        else None)
                      plan.steps
                  in
                  if concurrent then
                    prefetched := List.combine commands (read_many commands);
                  Ok ()
              | Build ->
                  built := true;
                  Ok ()
              | Create ->
                  let id = String.trim r.stdout in
                  if
                    String.length id <> 64
                    || not
                         (String.for_all
                            (function
                              | '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
                            id)
                  then fail (Runtime "Invalid created container ID")
                  else (
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
                    Ok ())
              | Start ->
                  started := true;
                  Ok ()
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
