type approval = {
  digest : string;
  trusted_at : float;
  deco_version : string;
  entries : Trust_digest.entry list;
}

type record = {
  project_root : string;
  project_name : string;
  approved : approval list;
}

let max_approvals = 16
let version = 1

let dir ?(getenv = Sys.getenv_opt) () =
  let absolute = function
    | Some path when (not (Filename.is_relative path)) && path <> "" ->
        Some path
    | Some _ | None -> None
  in
  let state =
    match absolute (getenv "XDG_STATE_HOME") with
    | Some state -> Some state
    | None -> (
        let home =
          match absolute (getenv "HOME") with
          | Some home -> Some home
          | None -> (
              try absolute (Some (Unix.getpwuid (Unix.getuid ())).Unix.pw_dir)
              with Not_found | Unix.Unix_error _ -> None)
        in
        match home with
        | Some home -> Some (Filename.concat home ".local/state")
        | None -> None)
  in
  match state with
  | Some state -> Ok (Filename.concat state "deco/trust")
  | None ->
      Error
        "Cannot locate the trust store: XDG_STATE_HOME and the home directory \
         are unavailable"

let record_path ~dir ~root =
  Filename.concat dir (Digest.BLAKE256.(to_hex (string root)) ^ ".json")

let to_json record =
  let approval a =
    `Assoc
      [
        ("digest", `String a.digest);
        ("trusted_at", `String (Timestamp.to_rfc3339 a.trusted_at));
        ("deco_version", `String a.deco_version);
        ( "entries",
          `Assoc
            (List.map
               (fun (e : Trust_digest.entry) -> (e.path, `String e.digest))
               a.entries) );
      ]
  in
  `Assoc
    [
      ("version", `Int version);
      ("project_root", `String record.project_root);
      ("project_name", `String record.project_name);
      ("approved", `List (List.map approval record.approved));
    ]

let of_json json =
  let open Yojson.Basic.Util in
  let string_field name json =
    match member name json with
    | `String s -> s
    | _ -> failwith ("missing or invalid " ^ name)
  in
  (match member "version" json with
  | `Int v when v = version -> ()
  | `Int v -> failwith ("unsupported version " ^ string_of_int v)
  | _ -> failwith "missing or invalid version");
  let approval json =
    let trusted_at =
      match Timestamp.parse (string_field "trusted_at" json) with
      | Some t -> t
      | None -> failwith "invalid trusted_at"
    in
    let entries =
      match member "entries" json with
      | `Assoc fields ->
          List.map
            (function
              | path, `String digest -> { Trust_digest.path; digest }
              | _ -> failwith "invalid entries")
            fields
      | _ -> failwith "missing or invalid entries"
    in
    {
      digest = string_field "digest" json;
      trusted_at;
      deco_version = string_field "deco_version" json;
      entries;
    }
  in
  {
    project_root = string_field "project_root" json;
    project_name = string_field "project_name" json;
    approved =
      (match member "approved" json with
      | `List approvals -> List.map approval approvals
      | _ -> failwith "missing or invalid approved");
  }

let read ~dir ~root =
  let path = record_path ~dir ~root in
  let ignored reason =
    (None, Some (Printf.sprintf "Ignoring trust record %s: %s" path reason))
  in
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ when not (Sys.file_exists path) -> (None, None)
  | exception Sys_error message -> ignored message
  | text -> (
      match of_json (Yojson.Basic.from_string text) with
      | record when record.project_root = root -> (Some record, None)
      | _ -> ignored "it belongs to a different project root"
      | exception (Failure message | Yojson.Json_error message) ->
          ignored message
      | exception Yojson.Basic.Util.Type_error (message, _) -> ignored message)

let unix_error path error = Error (path ^ ": " ^ Unix.error_message error)

(* Create [path] and missing parents with mode 0700, leaving existing
   directories untouched. *)
let rec make_dirs path =
  if Sys.file_exists path then Ok ()
  else
    match make_dirs (Filename.dirname path) with
    | Error _ as error -> error
    | Ok () -> (
        try Ok (Unix.mkdir path 0o700) with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
        | Unix.Unix_error (error, _, _) -> unix_error path error)

let write_atomically ~dir path contents =
  match Filename.temp_file ~temp_dir:dir ".record" ".tmp" with
  | exception Sys_error message -> Error message
  | temp -> (
      try
        let fd = Unix.openfile temp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () ->
            let length = String.length contents in
            let rec loop offset =
              if offset < length then
                loop
                  (offset
                  + Unix.write_substring fd contents offset (length - offset))
            in
            loop 0;
            Unix.fsync fd);
        Unix.rename temp path;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        (try Unix.unlink temp with Unix.Unix_error _ -> ());
        unix_error path error)

let approve ~dir ~root ~name ~deco_version ~now (digest : Trust_digest.t) =
  let previous =
    match read ~dir ~root with
    | Some record, _ -> record.approved
    | None, _ -> []
  in
  let approval =
    {
      digest = digest.digest;
      trusted_at = Float.trunc now;
      deco_version;
      entries = digest.entries;
    }
  in
  let approved =
    approval :: List.filter (fun a -> a.digest <> digest.digest) previous
    |> List.filteri (fun i _ -> i < max_approvals)
  in
  let record = { project_root = root; project_name = name; approved } in
  match make_dirs dir with
  | Error _ as error -> error
  | Ok () ->
      write_atomically ~dir (record_path ~dir ~root)
        (Yojson.Basic.pretty_to_string (to_json record) ^ "\n")

let revoke ~dir ~root =
  let path = record_path ~dir ~root in
  try
    Unix.unlink path;
    Ok true
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | Unix.Unix_error (error, _, _) -> unix_error path error
