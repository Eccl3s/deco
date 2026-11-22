type t = {
  container_name : string;
  start : Command_plan.argument list;
  post_start : Command_plan.argument list option;
}

let make (loaded : Config_loader.t) =
  let argv = Podman_command.start "" in
  let start =
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
         start
  then Error "Command arguments cannot contain NUL bytes"
  else
    Ok
      {
        container_name;
        start;
        post_start = Hook.command loaded Hook.Post_start;
      }

let post_start_step plan =
  Option.map
    (Hook.render_step ~condition:"If the container was started" Hook.Post_start)
    plan.post_start

let render plan =
  "Start preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps
      ([
         "Check Podman availability.";
         "Inspect the configured image and container "
         ^ Command_plan.quote plan.container_name
         ^ "; verify ownership, compatibility, and supported state. A missing \
            container fails; run deco assemble.";
         "If the container is not running, start it:\n"
         ^ Command_plan.render_multiline plan.start
         ^ "\n\
           \   Already-running containers require no mutation and run no hook.";
         "After starting, reinspect the same container and verify its ID, \
          ownership, compatibility, and running state.";
       ]
      @ Option.to_list (post_start_step plan))
  ^ "\n<container-id> is resolved by inspection during execution.\n"
