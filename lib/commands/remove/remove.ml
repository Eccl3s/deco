type mutation = Stop_container | Remove_container | Remove_image

type outcome = {
  stopped : bool;
  container_removed : bool;
  image_removed : bool;
}

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Image_in_use of Podman.container_summary list
  | Hook of Hook.failure

type error = { cause : cause; completed : mutation list }

let run ?run ?read_many ?(hooks = true) ?hook ?warn loaded ~keep_image =
  let injected_run = run in
  let run = Option.value ~default:(fun argv -> Process.run argv) run in
  let completed = ref [] in
  let fail cause = Error { cause; completed = List.rev !completed } in
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let wrap = function Ok x -> Ok x | Error e -> fail (Podman e) in
  let owned = function
    | Ok x -> Ok x
    | Error (Container_runtime.Podman e) -> fail (Podman e)
    | Error (Container_runtime.Conflict e) -> fail (Conflict e)
  in
  let container ?container_id () =
    owned (Container_runtime.inspect_owned_container ~run ?container_id loaded)
  in
  let image () = owned (Container_runtime.inspect_owned_image ~run loaded) in
  let mutate operation command =
    match run command with
    | Error e -> fail (Runtime (e.operation ^ ": " ^ e.message))
    | Ok r when r.Process.status = Unix.WEXITED 0 ->
        completed := operation :: !completed;
        Ok ()
    | Ok r -> fail (Runtime (Podman.message r))
  in
  let* plan =
    match Remove_plan.make ~hooks loaded ~keep_image with
    | Ok p -> Ok p
    | Error e -> fail (Planning e)
  in
  let commands =
    [
      Podman_command.version;
      Podman_command.inspect "container" plan.container_name;
    ]
    @
    match plan.image_reference with
    | None -> []
    | Some reference -> [ Podman_command.inspect "image" reference ]
  in
  let* initial_run =
    wrap (Container_runtime.preflight ?run:injected_run ?read_many commands)
  in
  let* () = wrap (Podman.available ~run:initial_run ()) in
  let* initial_container =
    owned (Container_runtime.inspect_owned_container ~run:initial_run loaded)
  in
  let* initial_image =
    if keep_image then Ok Podman.Absent
    else owned (Container_runtime.inspect_owned_image ~run:initial_run loaded)
  in
  let* stopped, container_removed =
    match initial_container with
    | Podman.Absent -> Ok (false, false)
    | Present c -> (
        let* stopped =
          match
            Stop.run ~run ~container_id:c.id ~check_availability:false ~hooks
              ?hook ?warn loaded
          with
          | Ok outcome ->
              if outcome.Stop.stopped then
                completed := Stop_container :: !completed;
              Ok outcome.stopped
          | Error e ->
              if e.Stop.stop_completed then
                completed := Stop_container :: !completed;
              fail
                (match e.cause with
                | Stop.Planning s -> Planning s
                | Stop.Podman e -> Podman e
                | Stop.Conflict s -> Conflict s
                | Stop.Runtime s -> Runtime s
                | Stop.Hook failure -> Hook failure)
        in
        let* current = container ~container_id:c.id () in
        match current with
        | Podman.Absent -> Ok (stopped, false)
        | Present current -> (
            if current.id <> c.id then
              fail (Conflict "Container ID changed before removal")
            else if
              current.state = "running"
              || not (Container_runtime.supported_state current.state)
            then fail (Conflict "Container is not stopped")
            else
              let* () =
                mutate Remove_container
                  (Command_plan.resolve ~image_id:"" ~container_id:c.id
                     plan.remove_container)
              in
              let* remaining = container ~container_id:c.id () in
              match remaining with
              | Podman.Absent -> Ok (stopped, true)
              | Present _ -> fail (Runtime "Container remains after removal")))
  in
  let* image_removed =
    match initial_image with
    | Podman.Absent -> Ok false
    | Present i -> (
        let* containers = wrap (Podman.list_containers ~run ()) in
        let dependents =
          List.filter
            (fun (c : Podman.container_summary) -> c.image_id = i.id)
            containers
          |> List.sort (fun (a : Podman.container_summary) b ->
              String.compare a.id b.id)
        in
        if dependents <> [] then fail (Image_in_use dependents)
        else
          let* current = image () in
          match current with
          | Podman.Absent -> Ok false
          | Present current -> (
              if current.id <> i.id then
                fail (Conflict "Image ID changed before removal")
              else
                let command = Option.get plan.remove_image in
                let* () =
                  mutate Remove_image
                    (Command_plan.resolve ~image_id:i.id ~container_id:""
                       command)
                in
                let* remaining = wrap (Podman.inspect_image ~run i.id) in
                match remaining with
                | Podman.Absent -> Ok true
                | Present _ -> fail (Runtime "Image remains after removal")))
  in
  Ok { stopped; container_removed; image_removed }
