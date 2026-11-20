type t = {
  start : Command_plan.argument list;
  exec : Command_plan.argument list;
}

let make (loaded : Config_loader.t) ~tty command =
  if command = [] then Error "At least one command argument is required"
  else
    let user =
      match loaded.identity with
      | User_identity.Image -> None
      | Keep_id { name; _ } -> Some name
    in
    let argv =
      Podman_command.exec ~tty ~user ~workdir:loaded.effective.container.workdir
        ~container:"" command
    in
    let container_index = List.length argv - List.length command - 1 in
    match Start_plan.make loaded with
    | Error e -> Error e
    | Ok start ->
        let plan =
          {
            start = start.Start_plan.start;
            exec =
              List.mapi
                (fun i value ->
                  if i = container_index then Command_plan.Container_id
                  else Literal value)
                argv;
          }
        in
        if
          List.exists
            (List.exists (function
              | Command_plan.Literal s -> String.contains s '\000'
              | _ -> false))
            [ plan.start; plan.exec ]
        then Error "Command arguments cannot contain NUL bytes"
        else Ok plan

let render t =
  "Exec preview\nNo commands will be run.\n\n"
  ^ "1. Check Podman availability.\n"
  ^ "2. Inspect the configured image and container; verify ownership, \
     compatibility, and supported state.\n"
  ^ "3. If the container is not running, start it:\n"
  ^ Command_plan.render_multiline t.start
  ^ "\n"
  ^ "   Then reinspect the same container and verify ownership, compatibility, \
     and running state.\n" ^ "4. Execute the command:\n"
  ^ Command_plan.render_multiline t.exec
  ^ "\n\n" ^ "<container-id> is resolved by inspection during execution.\n"
