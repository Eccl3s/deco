type t = { container_name : string; stop : Command_plan.argument list }

let make (loaded : Config_loader.t) =
  let argv = Podman_command.stop "" in
  let stop =
    List.mapi
      (fun i value ->
        if i = List.length argv - 1 then Command_plan.Container_id
        else Command_plan.Literal value)
      argv
  in
  let container_name = loaded.effective.container.name in
  if
    String.contains container_name '\000'
    || List.exists
         (function
           | Command_plan.Literal value -> String.contains value '\000'
           | Command_plan.Image_id | Command_plan.Container_id -> false)
         stop
  then Error "Command arguments cannot contain NUL bytes"
  else Ok { container_name; stop }

let render plan =
  "Stop preview\nNo commands will be run.\n\n"
  ^ "1. Check Podman availability.\n" ^ "2. Inspect container "
  ^ Command_plan.quote plan.container_name
  ^ " and verify project ownership and supported state.\n"
  ^ "3. If the container is running, stop it:\n"
  ^ Command_plan.render_multiline plan.stop
  ^ "\n   Already-stopped containers require no mutation.\n"
  ^ "4. After stopping, reinspect the same container and verify its ID, \
     ownership, and stopped state.\n\n"
  ^ "<container-id> is resolved by inspection during execution.\n"
