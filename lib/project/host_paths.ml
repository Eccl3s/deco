type protection = Protected | Unprotected | Disabled | Not_applicable
type protected_path = { source : string; target : string }

type t = {
  build_context : string;
  containerfile : string;
  workspace_source : string option;
  env_files : string list;
  protected : protected_path list;
  deco_protection : protection;
  git_protection : protection;
}

(* The path of [path] relative to [dir], both canonical: [Some ""] for [dir]
   itself, [None] when [path] is outside it. *)
let relative ~dir path =
  if path = dir then Some ""
  else
    let prefix = if dir = "/" then "/" else dir ^ "/" in
    if String.starts_with ~prefix path then
      Some
        (String.sub path (String.length prefix)
           (String.length path - String.length prefix))
    else None

(* [relative] appended to a container [target], which may end in [/]. *)
let container_path target relative =
  let rec trim s =
    let n = String.length s in
    if n > 1 && s.[n - 1] = '/' then trim (String.sub s 0 (n - 1)) else s
  in
  match (trim target, relative) with
  | target, "" -> target
  | "/", relative -> "/" ^ relative
  | target, relative -> target ^ "/" ^ relative

let protection ~(project : Project.t) ~workspace ~source =
  match (workspace, source) with
  | Some (w : Config.Effective.workspace), Some source -> (
      match relative ~dir:source project.root with
      | None ->
          ( [],
            Not_applicable,
            if w.protect_git then Not_applicable else Disabled )
      | Some root_relative ->
          let inside name =
            let host = Filename.concat project.root name in
            let relative =
              if root_relative = "" then name
              else Filename.concat root_relative name
            in
            { source = host; target = container_path w.target relative }
          in
          let deco =
            (* Discovery found .deco/config.toml, so .deco exists; protect the
               directory it resolves to when that is inside the workspace. *)
            match Unix.realpath (Filename.concat project.root ".deco") with
            | real -> (
                match relative ~dir:source real with
                | Some relative ->
                    Some
                      {
                        source = real;
                        target = container_path w.target relative;
                      }
                | None -> None)
            | exception Unix.Unix_error _ -> None
          in
          let git, git_state =
            if not w.protect_git then (None, Disabled)
            else
              match
                (Unix.lstat (Filename.concat project.root ".git")).st_kind
              with
              | Unix.S_DIR -> (Some (inside ".git"), Protected)
              | _ -> (None, Unprotected)
              | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                  (None, Not_applicable)
              | exception Unix.Unix_error _ -> (None, Unprotected)
          in
          ( Option.to_list deco @ Option.to_list git,
            (if deco = None then Not_applicable else Protected),
            git_state ))
  | Some w, None ->
      ([], Not_applicable, if w.protect_git then Not_applicable else Disabled)
  | None, _ -> ([], Not_applicable, Not_applicable)

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
      let protected, deco_protection, git_protection =
        protection ~project ~workspace:config.mounts.workspace
          ~source:workspace_source
      in
      Ok
        {
          build_context;
          containerfile;
          workspace_source;
          env_files;
          protected;
          deco_protection;
          git_protection;
        }
  | [], _, _ ->
      invalid_arg "Host_paths: missing resolved paths without diagnostics"
  | errors, _, _ -> Error (List.sort Config.Diagnostic.compare errors)
