type t = {
  build_context : string;
  containerfile : string;
  workspace_source : string option;
  env_files : string list;
}

let resolve ?home_dir ~(project : Project.t) (config : Config.Effective.t) =
  let errors = ref [] in
  let error path message =
    errors := Config.Diagnostic.{ path; message } :: !errors
  in
  let home =
    lazy
      (match home_dir with
      | Some home -> home
      | None -> (Unix.getpwuid (Unix.getuid ())).pw_dir)
  in
  let valid path value =
    if String.trim value = "" then (
      error path "Path must not be blank";
      false)
    else if String.contains value '\000' then (
      error path "Path must not contain NUL bytes";
      false)
    else true
  in
  let expand path value =
    if not (valid path value) then None
    else if value.[0] <> '~' then Some value
    else if value <> "~" && not (String.starts_with ~prefix:"~/" value) then (
      error path "Only ~ and ~/ home expansion are supported";
      None)
    else
      let directory = Lazy.force home in
      if not (valid path directory) then None
      else if Filename.is_relative directory then (
        error path "Home directory must be absolute";
        None)
      else if value = "~" then Some directory
      else
        Some
          (Filename.concat directory
             (String.sub value 2 (String.length value - 2)))
  in
  let resolve_path path ~base ~kind value =
    try
      Option.bind (expand path value) (fun value ->
          let absolute =
            if Filename.is_relative value then Filename.concat base value
            else value
          in
          let canonical = Unix.realpath absolute in
          if (Unix.stat canonical).st_kind = kind then Some canonical
          else (
            error path
              (if kind = Unix.S_DIR then "Expected an existing directory"
               else "Expected a regular file");
            None))
    with
    | Unix.Unix_error (reason, operation, filename) ->
        error path
          (Printf.sprintf "%s %s: %s" operation filename
             (Unix.error_message reason));
        None
    | Not_found ->
        error path "Current host user's home directory could not be found";
        None
  in
  let build_context =
    resolve_path [ "build"; "context" ] ~base:project.root ~kind:Unix.S_DIR
      config.build.context
  in
  let containerfile =
    Option.bind build_context (fun context ->
        Option.bind
          (resolve_path
             [ "build"; "containerfile" ]
             ~base:context ~kind:Unix.S_REG config.build.containerfile)
          (fun filename ->
            let prefix = if context = "/" then "/" else context ^ "/" in
            if String.starts_with ~prefix filename then Some filename
            else (
              error
                [ "build"; "containerfile" ]
                "Containerfile must be inside the canonical build context";
              None)))
  in
  let workspace_source =
    Option.bind config.mounts.workspace (fun workspace ->
        resolve_path
          [ "mounts"; "workspace"; "source" ]
          ~base:project.root ~kind:Unix.S_DIR workspace.source)
  in
  let env_files =
    List.concat
      (List.mapi
         (fun index value ->
           Option.to_list
             (resolve_path
                [ "container"; Printf.sprintf "env_files[%d]" index ]
                ~base:project.root ~kind:Unix.S_REG value))
         config.container.env_files)
  in
  match (!errors, build_context, containerfile) with
  | [], Some build_context, Some containerfile ->
      Ok { build_context; containerfile; workspace_source; env_files }
  | [], _, _ ->
      invalid_arg "Host_paths: missing resolved paths without diagnostics"
  | errors, _, _ -> Error (List.sort Config.Diagnostic.compare errors)
