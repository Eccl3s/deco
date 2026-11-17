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

let run ?(execute = fun output argv -> Process.run ~output argv) loaded =
  let selinux_enabled = ref true in
  let completed = ref [] in
  let fail cause = Error { cause; completed = List.rev !completed } in
  let ( let* ) result f =
    match result with Ok x -> f x | Error e -> Error e
  in
  let read argv = execute Process.Capture argv in
  let own labels =
    match
      Ownership.verify ~project:loaded.Config_loader.effective.project.name
        ~project_root:loaded.project.root labels
    with
    | Ok () -> Ok ()
    | Error _ -> fail (Conflict "Resource ownership differs")
  in
  let mutation output argv =
    match execute output argv with
    | Error e -> fail (Runtime (e.operation ^ ": " ^ e.message))
    | Ok r -> (
        match r.status with
        | Unix.WEXITED 0 ->
            completed :=
              String.concat " " (List.filteri (fun i _ -> i < 2) argv)
              :: !completed;
            Ok r
        | _ -> fail (Runtime (Podman.message r)))
  in
  let* plan =
    match Assemble_plan.make loaded with
    | Ok p -> Ok p
    | Error e -> fail (Planning e)
  in
  let image : Podman.image option ref = ref None in
  let container : Podman.container option ref = ref None in
  let image_exists = ref false and container_exists = ref false in
  let built = ref false and created = ref false and started = ref false in
  let ready () =
    let* () =
      match !image with None -> Ok () | Some i -> own i.Podman.labels
    in
    let* () =
      match !container with None -> Ok () | Some c -> own c.Podman.labels
    in
    match (!image, !container) with
    | None, Some _ ->
        fail (Conflict "Existing container has no configured image")
    | Some i, Some c ->
        let* () =
          match compatibility ~selinux_enabled:!selinux_enabled loaded i c with
          | Ok () -> Ok ()
          | Error e -> fail (Conflict e)
        in
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
        let* () = if index = Build then ready () else Ok () in
        let active =
          match index with
          | Availability | Image_exists | Container_exists -> true
          | Image_inspect -> !image_exists
          | Container_inspect -> !container_exists
          | Build -> !image = None
          | Built_exists | Built_inspect -> !built
          | Create -> !container = None
          | Created_exists | Created_inspect -> !created
          | Start -> (
              match !container with
              | Some c -> c.state <> "running"
              | None -> false)
          | Started_exists | Started_inspect -> !started
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
                      fail
                        (Podman (Unavailable (e.operation ^ ": " ^ e.message)))
                    else fail (Runtime (e.operation ^ ": " ^ e.message))
                | Ok r -> Ok r
            in
            let success = r.Process.status = Unix.WEXITED 0 in
            if
              List.mem index
                [
                  Image_exists;
                  Container_exists;
                  Built_exists;
                  Created_exists;
                  Started_exists;
                ]
            then
              if index = Image_exists && r.status = Unix.WEXITED 1 then (
                image_exists := false;
                Ok ())
              else if index = Container_exists && r.status = Unix.WEXITED 1 then (
                container_exists := false;
                Ok ())
              else if not success then fail (Runtime (Podman.message r))
              else (
                if index = Image_exists then image_exists := true;
                if index = Container_exists then container_exists := true;
                Ok ())
            else if not success then
              if index = Availability then
                fail (Podman (Unavailable (Podman.message r)))
              else fail (Runtime (Podman.message r))
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
                  let* () = own i.labels in
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
                  let* () = own c.labels in
                  let* () =
                    if index <> Container_inspect && c.id <> id_container ()
                    then fail (Conflict "Container ID differs")
                    else Ok ()
                  in
                  let* () =
                    match !image with
                    | Some i -> (
                        match
                          compatibility ~selinux_enabled:!selinux_enabled loaded
                            i c
                        with
                        | Ok () -> Ok ()
                        | Error e -> fail (Conflict e))
                    | None -> Ok ()
                  in
                  container := Some c;
                  if index = Started_inspect && c.state <> "running" then
                    fail (Runtime "Container is not running after start")
                  else Ok ()
              | Availability ->
                  selinux_enabled := Container_runtime.selinux_enabled r.stdout;
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
                        };
                    Ok ())
              | Start ->
                  started := true;
                  Ok ()
              | _ -> Ok ()
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
