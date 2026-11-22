let execute selection format =
  (* Listing reads configuration only: no trust, container or Podman is
     needed, except to locate a project by name. *)
  match Cli_common.load_project selection with
  | Error code -> code
  | Ok loaded ->
      let actions =
        loaded.Deco.Config_loader.effective.Config.Effective.actions
      in
      print_string
        (match format with
        | `Human -> Deco.Actions.render_human actions
        | `Json -> Deco.Actions.render_json actions);
      0

let command =
  let module Term = Cmdliner.Term in
  let format =
    Cli_common.format
      ~doc:
        "Output format: $(b,human) for aligned lines or $(b,json) for a stable \
         array."
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "actions" ~exits:Cli_common.exits
       ~doc:"List the configured actions, sorted by name.")
    Term.(const execute $ Cli_common.project $ format)
