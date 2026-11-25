type t = {
  container_name : string;
  stop : Command_plan.argument list;
  pre_stop : string option;
}

let pre_stop_step loaded ~hooks =
  if not hooks then None
  else
    Option.map
      (fun command ->
        Hook.render_step ~condition:"If the container is running" Hook.Pre_stop
          command
        ^ "\n\
          \   A failed hook leaves the container running and stops the \
           operation. If the container cannot run the hook as configured, the \
           hook is skipped with a warning.")
      (Hook.command loaded Hook.Pre_stop)

let make ?(hooks = true) (loaded : Config_loader.t) =
  let argv = Podman_command.stop "" in
  let stop =
    List.mapi
      (fun i value ->
        if i = List.length argv - 1 then Command_plan.Container_id
        else Command_plan.Literal value)
      argv
  in
  let container_name = loaded.effective.container.name in
  if String.contains container_name '\000' || Command_plan.contains_nul stop
  then Error "Command arguments cannot contain NUL bytes"
  else Ok { container_name; stop; pre_stop = pre_stop_step loaded ~hooks }

let render plan =
  "Stop preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps
      ([
         "Check Podman availability.";
         "Inspect container "
         ^ Command_plan.quote plan.container_name
         ^ " and verify project ownership and supported state.";
       ]
      @ Option.to_list plan.pre_stop
      @ [
          "If the container is running, stop it:\n"
          ^ Command_plan.render_multiline plan.stop
          ^ "\n   Already-stopped containers require no mutation.";
          "After stopping, reinspect the same container and verify its ID, \
           ownership, and stopped state.";
        ])
  ^ "\n<container-id> is resolved by inspection during execution.\n"
