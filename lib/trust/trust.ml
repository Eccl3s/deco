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

let store_dir = function
  | Some dir -> Ok dir
  | None -> Result.map_error (fun m -> Store m) (Trust_store.dir ())

let digest (loaded : Config_loader.t) =
  let deco_dir = Filename.concat loaded.project.Project.root ".deco" in
  match
    ( (try Ok (Unix.realpath deco_dir)
       with Unix.Unix_error (error, _, _) ->
         Error
           (Trust_digest.Filesystem (deco_dir ^ ": " ^ Unix.error_message error))),
      Trust_digest.compute ~deco_dir
        ~config:(loaded.project.Project.config_path, loaded.contents)
        ~containerfile:loaded.host_paths.Host_paths.containerfile )
  with
  | Error error, _ | _, Error error -> Error (Digest error)
  | Ok deco_dir, Ok digest -> Ok (deco_dir, digest)

let ( let* ) = Result.bind

let check ?store_dir:dir (loaded : Config_loader.t) =
  let root = loaded.project.Project.root in
  let* dir = store_dir dir in
  let* deco_dir, digest = digest loaded in
  let record, warning = Trust_store.read ~dir ~root in
  let warnings = Option.to_list warning in
  let status state trusted_at changes =
    Ok { state; root; deco_dir; digest; trusted_at; changes; warnings }
  in
  let approved =
    match record with Some record -> record.Trust_store.approved | None -> []
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
            (Trust_digest.diff ~approved:latest.entries ~current:digest.entries)
      )

let approve ?store_dir:dir ~deco_version ~now (loaded : Config_loader.t) =
  let* dir = store_dir dir in
  let* _, digest = digest loaded in
  Result.map_error
    (fun message -> Store message)
    (Trust_store.approve ~dir ~root:loaded.project.Project.root
       ~name:loaded.effective.project.name ~deco_version ~now digest)

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

let no_hooks_warning status =
  Printf.sprintf
    "deco: proceeding without hooks for configuration that is not trusted \
     (%s): %s; pre_stop is skipped.\n"
    (state_to_string status.state)
    (Terminal_text.escape status.root)

let dry_run_note ~command =
  Printf.sprintf
    "Note: configuration is not trusted; 'deco %s' would fail with exit code 5.\n"
    command

let error_to_string = function
  | Digest error -> Trust_digest.error_to_string error
  | Store message -> message
