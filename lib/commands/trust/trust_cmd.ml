type mode = Approve of { yes : bool; dry_run : bool } | Show | Revoke

type error =
  | Trust of Trust.error
  | Not_interactive
  | Declined
  | Changed_during_review
  | Store of string

let default_prompt question =
  print_string question;
  flush stdout;
  In_channel.input_line stdin

let confirmed answer =
  match String.lowercase_ascii (String.trim answer) with
  | "y" | "yes" -> true
  | _ -> false

let ( let* ) = Result.bind

let run ?store_dir ?(now = Unix.gettimeofday) ?(interactive = false)
    ?(prompt = default_prompt) ?(out = print_string) ?(err = prerr_string)
    ~deco_version mode (loaded : Config_loader.t) =
  let line fmt = Printf.ksprintf (fun s -> out (s ^ "\n")) fmt in
  let* dir =
    match store_dir with
    | Some dir -> Ok dir
    | None ->
        Result.map_error (fun m -> Trust (Trust.Store m)) (Trust_store.dir ())
  in
  let check ?(warn = true) () =
    let* status =
      Result.map_error (fun e -> Trust e) (Trust.check ~store_dir:dir loaded)
    in
    if warn then
      List.iter (fun warning -> err ("deco: " ^ warning ^ "\n")) status.warnings;
    Ok status
  in
  let root = loaded.project.Project.root in
  let safe_root = Terminal_text.escape root in
  match mode with
  | Revoke -> (
      match Trust_store.revoke ~dir ~root with
      | Ok true ->
          line "Trust revoked: %s" safe_root;
          Ok ()
      | Ok false ->
          line "Configuration was not trusted: %s" safe_root;
          Ok ()
      | Error message -> Error (Store message))
  | Show ->
      let* status = check () in
      let latest =
        match Trust_store.read ~dir ~root with
        | Some { approved = latest :: _; _ }, _ ->
            Timestamp.to_human ~now:(now ()) latest.trusted_at
        | Some { approved = []; _ }, _ | None, _ -> "-"
      in
      line "State:          %s" (Trust.state_to_string status.state);
      line "Root:           %s" safe_root;
      line "Digest:         %s" status.digest.digest;
      line "Last approved:  %s" latest;
      if status.changes <> [] then (
        line "Changes:";
        List.iter (line "%s") (Trust.render_changes status.changes));
      Ok ()
  | Approve { yes; dry_run } -> (
      let* status = check () in
      match status.state with
      | Trust.Trusted ->
          line "Configuration is already trusted: %s" safe_root;
          Ok ()
      | Trust.Changed | Trust.Untrusted ->
          out (Trust_review.render ~now:(now ()) status loaded);
          if dry_run then Ok ()
          else
            let* () =
              if yes then Ok ()
              else if not interactive then Error Not_interactive
              else (
                out "\n";
                match prompt "Trust this configuration? [y/N] " with
                | Some answer when confirmed answer -> Ok ()
                | Some _ | None -> Error Declined)
            in
            let* current = check ~warn:false () in
            if current.digest.digest <> status.digest.digest then
              Error Changed_during_review
            else
              let* () =
                Result.map_error
                  (fun message -> Store message)
                  (Trust_store.approve ~dir ~root
                     ~name:loaded.effective.project.name ~deco_version
                     ~now:(now ()) current.digest)
              in
              line "Trusted %s" safe_root;
              Ok ())

let error_to_string = function
  | Trust error -> Trust.error_to_string error
  | Not_interactive ->
      "Cannot ask for confirmation: stdin and stdout are not both terminals. \
       Rerun 'deco trust' in a terminal, or pass --yes to approve without \
       asking."
  | Declined -> "Configuration not trusted."
  | Changed_during_review ->
      ".deco/ changed while it was being reviewed; nothing was approved. Run \
       'deco trust' again to review the current contents."
  | Store message -> "Could not record trust: " ^ message
