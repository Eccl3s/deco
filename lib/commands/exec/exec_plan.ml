type t = {
  start : Command_plan.argument list;
  hooks : string list;
  exec : Command_plan.argument list;
}

let make (loaded : Config_loader.t) ~tty command =
  if command = [] then Error "At least one command argument is required"
  else
    let user = User_identity.exec_user loaded.identity in
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
            hooks = Start_plan.hook_steps start;
            exec =
              List.mapi
                (fun i value ->
                  if i = container_index then Command_plan.Container_id
                  else Literal value)
                argv;
          }
        in
        if List.exists Command_plan.contains_nul [ plan.start; plan.exec ] then
          Error "Command arguments cannot contain NUL bytes"
        else Ok plan

let prepare t =
  [
    "Check Podman availability.";
    "Inspect the configured image and container; verify ownership, \
     compatibility, and supported state.";
    "If the container is not running, start it:\n"
    ^ Command_plan.render_multiline t.start
    ^ "\n\
      \   Then reinspect the same container and verify ownership, \
       compatibility, and running state.";
  ]
  @ t.hooks

let render t =
  "Exec preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps
      (prepare t
      @ [ "Execute the command:\n" ^ Command_plan.render_multiline t.exec ])
  ^ "\n<container-id> is resolved by inspection during execution.\n"
