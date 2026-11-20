type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string

type error = { cause : cause; started : bool }
type outcome = { environment : Container_runtime.environment; started : bool }

let run ?run ?read_many ?(probe = fun () -> Container_runtime.local_selinux ())
    loaded =
  let injected = run in
  let run = Option.value ~default:(fun argv -> Process.run argv) run in
  let read_many =
    match (read_many, injected) with
    | Some batch, _ -> Some batch
    | None, Some _ -> None
    | None, None -> Some (fun commands -> Process.run_many commands)
  in
  let started = ref false in
  let fail cause = Error { cause; started = !started } in
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let selinux = Container_runtime.make_selinux_resolver ~run ~probe () in
  let inspect ?container_id () =
    match
      Container_runtime.inspect ?read_many ~selinux ~run ?container_id loaded
    with
    | Ok env -> Ok env
    | Error (Container_runtime.Podman e) -> fail (Podman e)
    | Error (Container_runtime.Conflict e) -> fail (Conflict e)
  in
  let* plan =
    match Start_plan.make loaded with
    | Ok plan -> Ok plan
    | Error e -> fail (Planning e)
  in
  let* initial = inspect () in
  let container_id = initial.container.id in
  if initial.container.state = "running" then
    Ok { environment = initial; started = false }
  else
    let argv =
      Command_plan.resolve ~image_id:initial.image.id ~container_id plan.start
    in
    let* result =
      match run argv with
      | Ok r -> Ok r
      | Error e -> fail (Runtime (e.operation ^ ": " ^ e.message))
    in
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
      else Ok { environment = current; started = true })
