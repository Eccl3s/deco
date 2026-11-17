type outcome = { container_id : string; stopped : bool }

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string

type error = { cause : cause; stop_completed : bool }

let run ?(run = fun argv -> Process.run argv) ?container_id
    ?(check_availability = true) loaded =
  let stop_completed = ref false in
  let fail cause = Error { cause; stop_completed = !stop_completed } in
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let inspect ?container_id () =
    match
      Container_runtime.inspect_owned_container ~run ?container_id loaded
    with
    | Ok value -> Ok value
    | Error (Container_runtime.Podman e) -> fail (Podman e)
    | Error (Container_runtime.Conflict e) -> fail (Conflict e)
  in
  let* plan =
    match Stop_plan.make loaded with
    | Ok plan -> Ok plan
    | Error e -> fail (Planning e)
  in
  let* () =
    match if check_availability then Podman.available ~run () else Ok () with
    | Ok () -> Ok ()
    | Error e -> fail (Podman e)
  in
  let* initial = inspect ?container_id () in
  let* container =
    match initial with
    | Podman.Absent -> fail (Conflict "Container is missing")
    | Present container -> Ok container
  in
  if
    match container_id with
    | Some expected -> expected <> container.id
    | None -> false
  then fail (Conflict "Container ID differs from selected ID")
  else if not (Container_runtime.supported_state container.state) then
    fail (Conflict "Unsupported container state")
  else if container.state <> "running" then
    Ok { container_id = container.id; stopped = false }
  else
    let argv =
      Command_plan.resolve ~image_id:"" ~container_id:container.id plan.stop
    in
    let* () =
      match run argv with
      | Error e -> fail (Runtime (e.operation ^ ": " ^ e.message))
      | Ok r when r.Process.status = Unix.WEXITED 0 ->
          stop_completed := true;
          Ok ()
      | Ok r -> fail (Runtime (Podman.message r))
    in
    let* current = inspect ~container_id:container.id () in
    match current with
    | Podman.Absent -> fail (Runtime "Container disappeared after stop")
    | Present current ->
        if current.id <> container.id then
          fail (Conflict "Container ID changed after stop")
        else if
          current.state = "running"
          || not (Container_runtime.supported_state current.state)
        then fail (Runtime "Container is not stopped after stop")
        else Ok { container_id = container.id; stopped = true }
