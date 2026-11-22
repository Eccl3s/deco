type t = Exec_plan.t

let make (loaded : Config_loader.t) =
  Exec_plan.make loaded ~tty:true [ loaded.effective.container.shell ]

let render (plan : t) =
  "Shell preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps
      (Exec_plan.prepare plan
      @ [
          "Enter the configured interactive shell:\n"
          ^ Command_plan.render_multiline plan.Exec_plan.exec;
        ])
  ^ "\n<container-id> is resolved by inspection during execution.\n"
