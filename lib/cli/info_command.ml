let execute selection format =
  match Cli_common.load_project selection with
  | Error code -> code
  | Ok loaded -> (
      (* info reports trust without requiring it. A failure to determine it
         still prints the report, like an unavailable Podman, but exits 2 as
         'deco trust' does. *)
      let trust =
        match Deco.Trust.check loaded with
        | Ok status ->
            List.iter
              (fun warning -> prerr_endline ("deco: " ^ warning))
              status.Deco.Trust.warnings;
            Some status
        | Error error ->
            prerr_endline ("deco: " ^ Deco.Trust.error_to_string error);
            None
      in
      match
        Deco.Info.collect ~trust
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
          Option.iter
            (fun reason -> prerr_endline ("deco: " ^ reason))
            unavailable;
          match (trust, unavailable) with
          | None, _ -> 2
          | Some _, Some _ -> 3
          | Some _, None -> 0)
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
