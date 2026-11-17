let execute arguments project_dir dry_run =
  match arguments with
  | None | Some [] ->
      prerr_endline "deco: exec requires -- followed by a command";
      2
  | Some arguments -> (
      match Cli_common.load_project project_dir with
      | Error code -> code
      | Ok loaded -> (
          let tty = Unix.isatty Unix.stdin && Unix.isatty Unix.stdout in
          if dry_run then (
            match Deco.Exec_plan.make loaded ~tty arguments with
            | Error message ->
                prerr_endline ("deco: " ^ message);
                2
            | Ok plan ->
                print_string (Deco.Exec_plan.render plan);
                0)
          else
            match
              Deco.Exec.run
                ~read_many:(fun commands ->
                  Deco.Process.run_many ~forward_signals:true commands)
                ~execute:(fun output argv ->
                  Deco.Process.run ~output ~forward_signals:true argv)
                loaded ~tty arguments
            with
            | Ok outcome -> (
                match outcome.Deco.Exec.status with
                | Unix.WEXITED code -> code
                | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
                    prerr_endline
                      "deco: executed process terminated without a normal exit \
                       status";
                    1)
            | Error error ->
                let message, code =
                  match error.Deco.Exec.cause with
                  | Deco.Exec.Planning e -> (e, 2)
                  | Deco.Exec.Conflict e -> (e, 4)
                  | Deco.Exec.Runtime e -> (e, 1)
                  | Deco.Exec.Podman (Deco.Podman.Unavailable e) -> (e, 3)
                  | Deco.Exec.Podman
                      ( Deco.Podman.Runtime { operation; message }
                      | Deco.Podman.Invalid_response { operation; message } ) ->
                      (operation ^ ": " ^ message, 1)
                in
                prerr_endline ("deco: " ^ message);
                if error.Deco.Exec.started [@warning "-42"] then
                  prerr_endline
                    "deco: Container was started and remains available.";
                code))

let command arguments =
  let module Arg = Cmdliner.Arg in
  let module Cmd = Cmdliner.Cmd in
  let module Term = Cmdliner.Term in
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:"Preview execution without invoking Podman.")
  in
  Cmd.v
    (Cmd.info "exec" ~exits:Cli_common.exits
       ~doc:"Execute a command in the development container.")
    Term.(const (execute arguments) $ Cli_common.project_dir $ dry_run)
