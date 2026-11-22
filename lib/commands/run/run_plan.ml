type error = Unknown_action of string | Planning of string

type t = {
  name : string;
  command : string;
  argv : string list;
  exec : Exec_plan.t;
}

let make (loaded : Config_loader.t) ~tty name =
  match List.assoc_opt name loaded.effective.actions with
  | None -> Error (Unknown_action name)
  | Some command -> (
      let argv = [ loaded.effective.container.shell; "-lc"; command ] in
      match Exec_plan.make loaded ~tty argv with
      | Error message -> Error (Planning message)
      | Ok exec -> Ok { name; command; argv; exec })

let render t =
  "Run preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps
      (Exec_plan.prepare t.exec
      @ [
          "Run action "
          ^ Terminal_text.escape t.name
          ^ ":\n"
          ^ Command_plan.render_multiline
              (Command_plan.escape_literals t.exec.Exec_plan.exec);
        ])
  ^ "\n<container-id> is resolved by inspection during execution.\n"
