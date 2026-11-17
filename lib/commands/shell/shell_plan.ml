type t = Exec_plan.t

let make (loaded : Config_loader.t) =
  Exec_plan.make loaded ~tty:true [ loaded.effective.container.shell ]

let render (plan : t) =
  "Shell preview\nNo commands will be run.\n\n"
  ^ "1. Check Podman availability.\n"
  ^ "2. Inspect the configured image and container; verify ownership, \
     compatibility, and supported state.\n"
  ^ "3. If the container is not running, start it:\n"
  ^ Command_plan.render_multiline plan.Exec_plan.start
  ^ "\n"
  ^ "   Then reinspect the same container and verify ownership, compatibility, \
     and running state.\n" ^ "4. Enter the configured interactive shell:\n"
  ^ Command_plan.render_multiline plan.Exec_plan.exec
  ^ "\n\n<container-id> is resolved by inspection during execution.\n"
