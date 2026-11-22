type t = { exec : Exec_plan.t; pre_enter : string option }

let make (loaded : Config_loader.t) =
  Result.map
    (fun exec ->
      {
        exec;
        pre_enter =
          Option.map
            (Hook.render_step ~condition:"Immediately before entering"
               Hook.Pre_enter)
            (Hook.command loaded Hook.Pre_enter);
      })
    (Exec_plan.make loaded ~tty:true [ loaded.effective.container.shell ])

let render plan =
  "Shell preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps
      (Exec_plan.prepare plan.exec
      @ Option.to_list plan.pre_enter
      @ [
          "Enter the configured interactive shell:\n"
          ^ Command_plan.render_multiline plan.exec.Exec_plan.exec;
        ])
  ^ "\n<container-id> is resolved by inspection during execution.\n"
