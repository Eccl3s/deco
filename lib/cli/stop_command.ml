let execute selection dry_run no_hooks =
  let open Config.Effective in
  match
    Cli_common.load_trusted_project ~no_hooks ~command:"stop" ~dry_run selection
  with
  | Error code -> code
  | Ok loaded -> (
      if dry_run then (
        match Deco.Stop_plan.make loaded with
        | Error message ->
            prerr_endline ("deco: " ^ message);
            2
        | Ok plan ->
            print_string (Deco.Stop_plan.render plan);
            0)
      else
        (* pre_stop runs here unless [no_hooks] (specs/deco-trust.md §6). Hooks
           are not implemented yet, so [no_hooks] only waives trust. *)
        match
          Deco.Stop.run
            ~read_many:(fun commands ->
              Deco.Process.run_many ~forward_signals:true commands)
            ~run:(fun argv -> Deco.Process.run ~forward_signals:true argv)
            loaded
        with
        | Ok outcome ->
            Printf.printf "%s %s\n"
              (if outcome.Deco.Stop.stopped then "Stopped"
               else "Already stopped:")
              loaded.Deco.Config_loader.effective.Config.Effective.container
                .name;
            0
        | Error error ->
            let message, code =
              match error.Deco.Stop.cause with
              | Deco.Stop.Planning e -> (e, 2)
              | Deco.Stop.Conflict e -> (e, 4)
              | Deco.Stop.Runtime e -> (e, 1)
              | Deco.Stop.Podman (Deco.Podman.Unavailable e) -> (e, 3)
              | Deco.Stop.Podman
                  ( Deco.Podman.Runtime { operation; message }
                  | Deco.Podman.Invalid_response { operation; message } ) ->
                  (operation ^ ": " ^ message, 1)
            in
            prerr_endline ("deco: " ^ message);
            if error.Deco.Stop.stop_completed then
              prerr_endline
                "deco: Stop command completed, but container shutdown could \
                 not be verified.";
            code)

let command =
  let module Arg = Cmdliner.Arg in
  let module Term = Cmdliner.Term in
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:
            "Preview shutdown without invoking Podman, except to locate a \
             $(b,--project).")
  in
  let no_hooks =
    Arg.(
      value & flag
      & info [ "no-hooks" ]
          ~doc:
            "Skip the $(b,pre_stop) hook. The configuration then need not be \
             trusted; a warning is printed when it is not.")
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "stop" ~exits:Cli_common.exits
       ~doc:"Stop the managed development container.")
    Term.(const execute $ Cli_common.project $ dry_run $ no_hooks)
