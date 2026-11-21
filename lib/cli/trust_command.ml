module Arg = Cmdliner.Arg
module Term = Cmdliner.Term
module Cmd = Cmdliner.Cmd

let execute selection yes dry_run show revoke =
  let mode =
    match (show, revoke) with
    | true, true -> Error "--show and --revoke are mutually exclusive"
    | true, false when yes || dry_run ->
        Error "--show cannot be combined with --yes or --dry-run"
    | false, true when yes || dry_run ->
        Error "--revoke cannot be combined with --yes or --dry-run"
    | true, false -> Ok Deco.Trust_cmd.Show
    | false, true -> Ok Deco.Trust_cmd.Revoke
    | false, false -> Ok (Deco.Trust_cmd.Approve { yes; dry_run })
  in
  match mode with
  | Error message ->
      prerr_endline ("deco: " ^ message);
      2
  | Ok mode -> (
      match Cli_common.load_project selection with
      | Error code -> code
      | Ok loaded -> (
          match
            Deco.Trust_cmd.run
              ~interactive:(Unix.isatty Unix.stdin && Unix.isatty Unix.stdout)
              ~deco_version:Generated_version.value mode loaded
          with
          | Ok () -> 0
          | Error error ->
              let message = Deco.Trust_cmd.error_to_string error in
              let code =
                match error with
                | Deco.Trust_cmd.Declined ->
                    prerr_endline message;
                    1
                | Deco.Trust_cmd.Trust (Deco.Trust.Digest _)
                | Deco.Trust_cmd.Not_interactive ->
                    prerr_endline ("deco: " ^ message);
                    2
                | Deco.Trust_cmd.Trust (Deco.Trust.Store _)
                | Deco.Trust_cmd.Changed_during_review | Deco.Trust_cmd.Store _
                  ->
                    prerr_endline ("deco: " ^ message);
                    1
              in
              code))

let command =
  let flag names doc = Arg.(value & flag & info names ~doc) in
  let yes =
    flag [ "y"; "yes" ]
      "Approve the configuration without asking for confirmation."
  and dry_run =
    flag [ "d"; "dry-run" ]
      "Print the review without asking for confirmation or recording an \
       approval."
  and show =
    flag [ "show" ]
      "Print the trust state, digest, last approval and changes, without the \
       review."
  and revoke =
    flag [ "revoke" ] "Remove every approval recorded for the project root."
  in
  Cmd.v
    (Cmd.info "trust" ~exits:Cli_common.exits
       ~doc:"Review and approve the project configuration."
       ~man:
         [
           `P
             "Commands that build, create, start, stop or remove resources \
              require the exact contents of .deco/ to be approved first. \
              $(b,deco trust) prints a review of the configuration and asks \
              for confirmation. Approvals are stored per user under \
              \\$XDG_STATE_HOME/deco/trust, or ~/.local/state/deco/trust.";
         ])
    Term.(const execute $ Cli_common.project $ yes $ dry_run $ show $ revoke)
