type t = { root : string; config_path : string }

type error =
  | Not_found of { start_dir : string }
  | Missing_config of { root : string }
  | Not_directory of { path : string }
  | Not_regular_file of { path : string }
  | Filesystem_error of {
      operation : string;
      path : string;
      reason : Unix.error;
    }

let error_to_string = function
  | Not_found { start_dir } -> "No Deco project found from " ^ start_dir
  | Missing_config { root } ->
      "Missing configuration: " ^ Filename.concat root ".deco/config.toml"
  | Not_directory { path } -> "Not a directory: " ^ path
  | Not_regular_file { path } -> "Not a regular file: " ^ path
  | Filesystem_error { operation; path; reason } ->
      Printf.sprintf "%s %s: %s" operation path (Unix.error_message reason)

let protect f =
  try f ()
  with Unix.Unix_error (reason, operation, path) ->
    Error (Filesystem_error { operation; path; reason })

let directory path =
  protect (fun () ->
      let root = Unix.realpath path in
      if (Unix.stat root).st_kind = Unix.S_DIR then Ok root
      else Error (Not_directory { path = root }))

let stat_optional path =
  try Some (Unix.stat path) with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let candidate root =
  protect (fun () ->
      let deco = Filename.concat root ".deco" in
      let config_path = Filename.concat deco "config.toml" in
      match stat_optional deco with
      | None -> Ok None
      | Some stat when stat.st_kind <> Unix.S_DIR ->
          Error (Not_directory { path = deco })
      | Some _ -> (
          match stat_optional config_path with
          | None -> Ok None
          | Some stat when stat.st_kind = Unix.S_REG ->
              Ok (Some { root; config_path })
          | Some _ -> Error (Not_regular_file { path = config_path })))

let select ~directory:path =
  match directory path with
  | Error error -> Error error
  | Ok root -> (
      match candidate root with
      | Error error -> Error error
      | Ok (Some project) -> Ok project
      | Ok None -> Error (Missing_config { root }))

let discover ~start_dir =
  match directory start_dir with
  | Error error -> Error error
  | Ok start_dir ->
      let rec search root =
        match candidate root with
        | Error error -> Error error
        | Ok (Some project) -> Ok project
        | Ok None ->
            let parent = Filename.dirname root in
            if parent = root then Error (Not_found { start_dir })
            else search parent
      in
      search start_dir
