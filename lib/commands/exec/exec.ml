type runner =
  Process.output -> string list -> (Process.result, Process.error) result

type cause = Start.cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Hook of Hook.failure

type error = Start.error = { cause : cause; started : bool }

type outcome = {
  container_id : string;
  started : bool;
  status : Unix.process_status;
}

let run ?execute ?read_many ?probe ?hook
    ?(before_exec = fun ~container_id:_ -> Ok ()) loaded ~tty command =
  let injected = execute in
  let execute =
    Option.value ~default:(fun output argv -> Process.run ~output argv) execute
  in
  let read_many =
    match (read_many, injected) with
    | Some batch, _ -> Some batch
    | None, Some _ -> None
    | None, None -> Some (fun commands -> Process.run_many commands)
  in
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let* plan =
    match Exec_plan.make loaded ~tty command with
    | Ok plan -> Ok plan
    | Error e -> Error { cause = Planning e; started = false }
  in
  let* { Start.environment; started } =
    Start.run ~run:(execute Process.Capture) ?read_many ?probe ?hook loaded
  in
  let container_id = environment.container.id in
  let argv =
    Command_plan.resolve ~image_id:environment.image.id ~container_id plan.exec
  in
  let* () =
    match before_exec ~container_id with
    | Ok () -> Ok ()
    | Error failure -> Error { cause = Hook failure; started }
  in
  match execute Process.Inherit argv with
  | Ok result -> Ok { container_id; started; status = result.status }
  | Error e ->
      Error { cause = Runtime (e.operation ^ ": " ^ e.message); started }
