type t = { container_name : string; start : Command_plan.argument list }

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
  else Ok { container_name; start }
