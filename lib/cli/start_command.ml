let execute selection dry_run =
  let open Config.Effective in
  match Cli_common.load_trusted_project ~command:"start" ~dry_run selection with
  | Error code -> code
  | Ok loaded -> (
      if dry_run then (
        match Deco.Start_plan.make loaded with
        | Error message ->
            prerr_endline ("deco: " ^ message);
            2
        | Ok plan ->
            print_string (Deco.Start_plan.render plan);
            0)
      else
        match
          Deco.Start.run
            ~read_many:(fun commands ->
              Deco.Process.run_many ~forward_signals:true commands)
            ~run:(fun argv -> Deco.Process.run ~forward_signals:true argv)
            loaded
        with
        | Ok outcome ->
            Printf.printf "%s %s\n"
              (if outcome.Deco.Start.started then "Started"
               else "Already running:")
              loaded.Deco.Config_loader.effective.Config.Effective.container
                .name;
            0
        | Error error ->
            let message, code =
              match error.Deco.Start.cause with
              | Deco.Start.Planning e -> (e, 2)
              | Deco.Start.Conflict e -> (e, 4)
              | Deco.Start.Runtime e -> (e, 1)
              | Deco.Start.Hook failure ->
                  ( Deco.Hook.failure_message failure,
                    Deco.Hook.exit_status failure )
              | Deco.Start.Podman (Deco.Podman.Unavailable e) -> (e, 3)
              | Deco.Start.Podman
                  ( Deco.Podman.Runtime { operation; message }
                  | Deco.Podman.Invalid_response { operation; message } ) ->
                  (operation ^ ": " ^ message, 1)
            in
            prerr_endline ("deco: " ^ message);
            (match error.Deco.Start.cause with
            | Deco.Start.Hook _ ->
                prerr_endline
                  ("deco: Started "
                 ^ loaded.Deco.Config_loader.effective
                     .Config.Effective.container
                     .name ^ "; it remains running.")
            | Deco.Start.Planning _ | Deco.Start.Conflict _
            | Deco.Start.Runtime _ | Deco.Start.Podman _ ->
                if error.Deco.Start.started [@warning "-42"] then
                  prerr_endline
                    "deco: Start command completed, but container startup \
                     could not be verified.");
            code)

let command =
  let module Arg = Cmdliner.Arg in
  let module Term = Cmdliner.Term in
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:
            "Preview startup without invoking Podman, except to locate a \
             $(b,--project).")
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "start" ~exits:Cli_common.exits
       ~doc:"Start the existing development container.")
    Term.(const execute $ Cli_common.project $ dry_run)
