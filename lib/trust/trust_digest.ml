type entry = { path : string; digest : string }
type t = { digest : string; entries : entry list }
type error = Unsupported_entry of string | Filesystem of string

exception Failed of error

let hash data = "blake2b-256:" ^ Digest.BLAKE256.(to_hex (string data))

(* Each record is a type tag, then length-prefixed fields. Lengths are 64-bit
   big-endian, so no record is a prefix of a different one. *)
let record tag path content =
  let buffer = Buffer.create (17 + String.length path) in
  let field data =
    Buffer.add_int64_be buffer (Int64.of_int (String.length data));
    Buffer.add_string buffer data
  in
  Buffer.add_char buffer tag;
  field path;
  Option.iter field content;
  Buffer.contents buffer

let fail_unix path error =
  raise (Failed (Filesystem (path ^ ": " ^ Unix.error_message error)))

let realpath path =
  try Unix.realpath path
  with Unix.Unix_error (error, _, _) -> fail_unix path error

let read path =
  try In_channel.with_open_bin path In_channel.input_all
  with Sys_error message -> raise (Failed (Filesystem message))

let relative_to ~dir path =
  let prefix = if String.ends_with ~suffix:"/" dir then dir else dir ^ "/" in
  if String.starts_with ~prefix path && path <> prefix then
    Some
      (String.sub path (String.length prefix)
         (String.length path - String.length prefix))
  else None

(* Every entry beneath [root] as (relative path, absolute path), unsorted. *)
let walk root =
  let rec visit relative_dir absolute_dir acc =
    let names =
      try Sys.readdir absolute_dir
      with Sys_error message -> raise (Failed (Filesystem message))
    in
    Array.fold_left
      (fun acc name ->
        let rel =
          if relative_dir = "" then name else relative_dir ^ "/" ^ name
        in
        let abs = Filename.concat absolute_dir name in
        let stats =
          try Unix.lstat abs
          with Unix.Unix_error (error, _, _) -> fail_unix abs error
        in
        let acc = (rel, abs, stats.Unix.st_kind) :: acc in
        if stats.Unix.st_kind = Unix.S_DIR then visit rel abs acc else acc)
      acc names
  in
  visit "" root []

let compute ~deco_dir ~config:(config_path, contents) ~containerfile =
  try
    let deco = realpath deco_dir in
    let config = realpath config_path in
    let override = relative_to ~dir:deco config in
    let internal =
      List.map
        (fun (rel, abs, kind) ->
          match kind with
          | Unix.S_DIR -> (rel, record 'd' rel None)
          | Unix.S_REG ->
              let data = if Some rel = override then contents else read abs in
              (rel, record 'f' rel (Some data))
          | Unix.S_LNK ->
              let target =
                try Unix.readlink abs
                with Unix.Unix_error (error, _, _) -> fail_unix abs error
              in
              (rel, record 'l' rel (Some target))
          | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
              raise (Failed (Unsupported_entry abs)))
        (walk deco)
    in
    let external_config =
      if override = None then [ (config, record 'f' config (Some contents)) ]
      else []
    in
    let containerfile = realpath containerfile in
    let external_containerfile =
      if relative_to ~dir:deco containerfile <> None || containerfile = config
      then []
      else
        [
          (containerfile, record 'f' containerfile (Some (read containerfile)));
        ]
    in
    let records =
      List.sort
        (fun (a, _) (b, _) -> String.compare a b)
        (internal @ external_config @ external_containerfile)
    in
    Ok
      {
        digest = hash (String.concat "" (List.map snd records));
        entries =
          List.map (fun (path, data) -> { path; digest = hash data }) records;
      }
  with Failed error -> Error error

type change = Added | Modified | Removed

let diff ~approved ~current =
  let find path entries =
    List.find_map
      (fun (entry : entry) ->
        if entry.path = path then Some entry.digest else None)
      entries
  in
  let changes =
    List.filter_map
      (fun (entry : entry) ->
        match find entry.path approved with
        | None -> Some (entry.path, Added)
        | Some digest when digest <> entry.digest -> Some (entry.path, Modified)
        | Some _ -> None)
      current
    @ List.filter_map
        (fun (entry : entry) ->
          match find entry.path current with
          | None -> Some (entry.path, Removed)
          | Some _ -> None)
        approved
  in
  List.sort (fun (a, _) (b, _) -> String.compare a b) changes

let change_to_string = function
  | Added -> "added"
  | Modified -> "modified"
  | Removed -> "removed"

let error_to_string = function
  | Unsupported_entry path ->
      path
      ^ ": unsupported file type in .deco (only directories, regular files and \
         symlinks are allowed)"
  | Filesystem message -> message
