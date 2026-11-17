type runner =
  Process.output -> string list -> (Process.result, Process.error) result

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string

type error = { cause : cause; started : bool }

type outcome = {
  container_id : string;
  started : bool;
  status : Unix.process_status;
}

let run ?execute ?read_many
    ?(probe = fun () -> Container_runtime.local_selinux ()) loaded ~tty command
    =
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
  let started = ref false in
  let fail cause = Error { cause; started = !started } in
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let selinux =
    Container_runtime.make_selinux_resolver ~run:(execute Process.Capture)
      ~probe ()
  in
  let inspect ?container_id () =
    match
      Container_runtime.inspect
        ~read_many:
          (if Option.is_some container_id then
             List.map (execute Process.Capture)
           else read_many)
        ~selinux ~run:(execute Process.Capture) ?container_id loaded
    with
    | Ok env -> Ok env
    | Error (Container_runtime.Podman e) -> fail (Podman e)
    | Error (Container_runtime.Conflict e) -> fail (Conflict e)
  in
  let invoke output argv =
    match execute output argv with
    | Ok r -> Ok r
    | Error e -> fail (Runtime (e.operation ^ ": " ^ e.message))
  in
  let* plan =
    match Exec_plan.make loaded ~tty command with
    | Ok plan -> Ok plan
    | Error e -> fail (Planning e)
  in
  let* initial = inspect () in
  let container_id = initial.container.id in
  let resolve = Command_plan.resolve ~image_id:initial.image.id ~container_id in
  let* () =
    if initial.container.state = "running" then Ok ()
    else
      let* result = invoke Process.Capture (resolve plan.start) in
      if result.status <> Unix.WEXITED 0 then
        fail (Runtime (Podman.message result))
      else (
        started := true;
        let* current = inspect ~container_id () in
        if
          current.container.id <> container_id
          || current.image.id <> initial.image.id
        then fail (Conflict "Resource ID changed after start")
        else if current.container.state <> "running" then
          fail (Runtime "Container is not running after start")
        else Ok ())
  in
  let* result = invoke Process.Inherit (resolve plan.exec) in
  Ok { container_id; started = !started; status = result.status }
