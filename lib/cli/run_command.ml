let unknown_action name =
  prerr_endline
    ("deco: Unknown action \""
    ^ Deco.Terminal_text.escape name
    ^ "\"; run 'deco actions' to list the configured actions.");
  2

let execute selection dry_run name =
  match Cli_common.load_trusted_project ~command:"run" ~dry_run selection with
  | Error code -> code
  | Ok loaded -> (
      let tty = Unix.isatty Unix.stdin && Unix.isatty Unix.stdout in
      if dry_run then (
        match Deco.Run_plan.make loaded ~tty name with
        | Error (Deco.Run_plan.Unknown_action name) -> unknown_action name
        | Error (Deco.Run_plan.Planning message) ->
            prerr_endline ("deco: " ^ message);
            2
        | Ok plan ->
            print_string (Deco.Run_plan.render plan);
            0)
      else
        match
          Deco.Run.run
            ~read_many:(fun commands ->
              Deco.Process.run_many ~forward_signals:true commands)
            ~execute:(fun output argv ->
              Deco.Process.run ~output ~forward_signals:true argv)
            loaded ~tty name
        with
        | Error (Deco.Run.Unknown_action name) -> unknown_action name
        | Error (Deco.Run.Exec error) ->
            Cli_common.report_execution_result (Error error)
        | Ok outcome -> Cli_common.report_execution_result (Ok outcome))

let command =
  let module Arg = Cmdliner.Arg in
  let module Cmd = Cmdliner.Cmd in
  let module Term = Cmdliner.Term in
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:
            "Preview the action without invoking Podman, except to locate a \
             $(b,--project).")
  in
  let action =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"ACTION"
          ~doc:"The configured action to run; see $(b,deco actions).")
  in
  Cmd.v
    (Cmd.info "run" ~exits:Cli_common.exits
       ~doc:"Run a configured action in the development container.")
    Term.(const execute $ Cli_common.project $ dry_run $ action)
