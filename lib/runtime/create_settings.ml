let label = "dev.deco.create-digest"

let length_prefixed values =
  let buffer = Buffer.create 64 in
  List.iter
    (fun value ->
      Buffer.add_int64_be buffer (Int64.of_int (String.length value));
      Buffer.add_string buffer value)
    values;
  Buffer.contents buffer

let fields (loaded : Config_loader.t) =
  let c = loaded.effective.container in
  (if c.privileged then [ ("container.privileged", "true") ] else [])
  @ List.filter_map
      (fun (key, values) ->
        if values = [] then None
        else Some ("container." ^ key, length_prefixed values))
      [
        ("devices", c.devices);
        ("cap_add", c.cap_add);
        ("cap_drop", c.cap_drop);
        ("security_options", c.security_options);
        ("env_files", loaded.host_paths.env_files);
        ( "environment",
          List.concat_map (fun (name, value) -> [ name; value ]) c.environment
        );
      ]
  @
  match loaded.host_paths.protected with
  | [] -> []
  | paths ->
      [
        ( "mounts.protected",
          length_prefixed
            (List.concat_map
               (fun (p : Host_paths.protected_path) -> [ p.source; p.target ])
               paths) );
      ]

(* Each pair is its key then its value, each prefixed with its length as a
   64-bit big-endian integer, so no encoding is a prefix of a different one. *)
let digest pairs =
  let pairs = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs in
  let rec unique = function
    | (a, _) :: ((b, _) :: _ as rest) ->
        if a = b then invalid_arg ("Create_settings.digest: duplicate key " ^ a)
        else unique rest
    | _ -> ()
  in
  unique pairs;
  let buffer = Buffer.create 64 in
  let field data =
    Buffer.add_int64_be buffer (Int64.of_int (String.length data));
    Buffer.add_string buffer data
  in
  List.iter
    (fun (key, value) ->
      field key;
      field value)
    pairs;
  "blake2b-256:" ^ Digest.BLAKE256.(to_hex (string (Buffer.contents buffer)))

let of_loaded loaded = digest (fields loaded)
