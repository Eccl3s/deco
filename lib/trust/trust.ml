type state = Trusted | Changed | Untrusted

type status = {
  state : state;
  root : string;
  deco_dir : string;
  digest : Trust_digest.t;
  trusted_at : float option;
  changes : (string * Trust_digest.change) list;
  warnings : string list;
}

type error = Digest of Trust_digest.error | Store of string

let check ?store_dir (loaded : Config_loader.t) =
  let root = loaded.project.Project.root in
  let store_dir =
    match store_dir with Some dir -> Ok dir | None -> Trust_store.dir ()
  in
  match store_dir with
  | Error message -> Error (Store message)
  | Ok dir -> (
      let deco_dir = Filename.concat root ".deco" in
      match
        ( (try Ok (Unix.realpath deco_dir)
           with Unix.Unix_error (error, _, _) ->
             Error
               (Trust_digest.Filesystem
                  (deco_dir ^ ": " ^ Unix.error_message error))),
          Trust_digest.compute ~deco_dir
            ~config:(loaded.project.Project.config_path, loaded.contents)
            ~containerfile:loaded.host_paths.Host_paths.containerfile )
      with
      | Error error, _ | _, Error error -> Error (Digest error)
      | Ok deco_dir, Ok digest -> (
          let record, warning = Trust_store.read ~dir ~root in
          let warnings = Option.to_list warning in
          let status state trusted_at changes =
            Ok { state; root; deco_dir; digest; trusted_at; changes; warnings }
          in
          let approved =
            match record with
            | Some record -> record.Trust_store.approved
            | None -> []
          in
          match
            List.find_opt
              (fun (a : Trust_store.approval) -> a.digest = digest.digest)
              approved
          with
          | Some approval -> status Trusted (Some approval.trusted_at) []
          | None -> (
              match (record, approved) with
              | None, _ -> status Untrusted None []
              | Some _, [] -> status Changed None []
              | Some _, latest :: _ ->
                  status Changed (Some latest.trusted_at)
                    (Trust_digest.diff ~approved:latest.entries
                       ~current:digest.entries))))

let state_to_string = function
  | Trusted -> "trusted"
  | Changed -> "changed"
  | Untrusted -> "untrusted"

let render_changes changes =
  List.map
    (fun (path, change) ->
      Printf.sprintf "  %-8s  %s"
        (Trust_digest.change_to_string change)
        (Terminal_text.escape path))
    changes

let failure_message ~command status =
  let root = Terminal_text.escape status.root in
  let headline =
    match status.state with
    | Changed ->
        Printf.sprintf "configuration for %s has changed since it was trusted"
          root
    | Trusted | Untrusted ->
        Printf.sprintf "configuration for %s is not trusted" root
  in
  let hints =
    "Run 'deco trust' to review and approve it."
    ::
    (match command with
    | "stop" | "remove" ->
        [
          Printf.sprintf
            "Or run 'deco %s --no-hooks' to %s without running hooks." command
            command;
        ]
    | _ -> [])
  in
  String.concat ""
    (List.map
       (fun line -> line ^ "\n")
       ((("deco: " ^ headline) :: render_changes status.changes) @ hints))

let dry_run_note ~command =
  Printf.sprintf
    "Note: configuration is not trusted; 'deco %s' would fail with exit code 5.\n"
    command

let error_to_string = function
  | Digest error -> Trust_digest.error_to_string error
  | Store message -> message
