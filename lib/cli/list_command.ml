let execute format =
  match
    Deco.Managed_list.run
      ~run:(fun argv -> Deco.Process.run ~forward_signals:true argv)
      ()
  with
  | Ok entries ->
      print_string
        (match format with
        | `Human -> Deco.Managed_list.render_human entries
        | `Json -> Deco.Managed_list.render_json entries);
      0
  | Error error ->
      let message, code =
        match error with
        | Deco.Podman.Unavailable message -> (message, 3)
        | Deco.Podman.Runtime { operation; message }
        | Deco.Podman.Invalid_response { operation; message } ->
            (operation ^ ": " ^ message, 1)
      in
      prerr_endline ("deco: " ^ message);
      code

let command =
  let module Arg = Cmdliner.Arg in
  let module Term = Cmdliner.Term in
  let format =
    Arg.(
      value
      & opt (enum [ ("human", `Human); ("json", `Json) ]) `Human
      & info Argv.format.Argv.names ~docv:"FORMAT"
          ~doc:
            "Output format: $(b,human) for a table or $(b,json) for a stable \
             array.")
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "list" ~exits:Cli_common.exits
       ~doc:
         "List Deco-managed containers across all projects, running or stopped.")
    Term.(const execute $ format)
