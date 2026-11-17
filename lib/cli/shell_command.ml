let execute project_dir dry_run =
  let tty = Unix.isatty Unix.stdin && Unix.isatty Unix.stdout in
  if (not dry_run) && not tty then (
    prerr_endline "deco: Shell entry requires stdin and stdout to be terminals";
    2)
  else
    match Cli_common.load_project project_dir with
    | Error code -> code
    | Ok loaded ->
        if dry_run then (
          match Deco.Shell_plan.make loaded with
          | Error message ->
              prerr_endline ("deco: " ^ message);
              2
          | Ok plan ->
              print_string (Deco.Shell_plan.render plan);
              0)
        else
          Cli_common.report_execution_result
            (Deco.Shell.run
               ~execute:(fun output argv ->
                 Deco.Process.run ~output ~forward_signals:true argv)
               ~read_many:(fun commands ->
                 Deco.Process.run_many ~forward_signals:true commands)
               loaded ~tty)

let command =
  let module Arg = Cmdliner.Arg in
  let module Term = Cmdliner.Term in
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:"Preview shell entry without invoking Podman.")
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "shell" ~exits:Cli_common.exits
       ~doc:"Enter the configured interactive shell.")
    Term.(const execute $ Cli_common.project_dir $ dry_run)
