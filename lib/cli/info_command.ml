let execute selection format =
  match Cli_common.load_project selection with
  | Error code -> code
  | Ok loaded -> (
      match
        Deco.Info.collect
          ~read_many:(fun commands ->
            Deco.Process.run_many ~forward_signals:true commands)
          ~run:(fun argv -> Deco.Process.run ~forward_signals:true argv)
          loaded
      with
      | Ok (report, unavailable) -> (
          print_string
            (match format with
            | `Human ->
                Deco.Info.render_human ~now:(Unix.gettimeofday ())
                  ~ignored:loaded.Deco.Config_loader.ignored_paths report
            | `Json -> Deco.Info.render_json report);
          match unavailable with
          | None -> 0
          | Some reason ->
              prerr_endline ("deco: " ^ reason);
              3)
      | Error error ->
          let message, code =
            match error with
            | Deco.Podman.Unavailable message -> (message, 3)
            | Deco.Podman.Runtime { operation; message }
            | Deco.Podman.Invalid_response { operation; message } ->
                (operation ^ ": " ^ message, 1)
          in
          prerr_endline ("deco: " ^ message);
          code)

let command =
  let module Term = Cmdliner.Term in
  let format =
    Cli_common.format
      ~doc:
        "Output format: $(b,human) for labelled sections or $(b,json) for a \
         stable object."
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "info" ~exits:Cli_common.exits
       ~doc:"Show project configuration and Podman resource state.")
    Term.(const execute $ Cli_common.project $ format)
