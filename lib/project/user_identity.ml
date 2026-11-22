type ids = { uid : int; gid : int }
type t = Image | Keep_id of { name : string; host : ids; container : ids }

let exec_user = function Image -> None | Keep_id { name; _ } -> Some name

let default_host_ids () =
  try Ok { uid = Unix.getuid (); gid = Unix.getgid () }
  with Unix.Unix_error (reason, operation, _) ->
    Error (operation ^ ": " ^ Unix.error_message reason)

let resolve ?(host_ids = default_host_ids) (user : Config.Effective.user) =
  let errors = ref [] in
  let error key message =
    errors := Config.Diagnostic.{ path = key; message } :: !errors
  in
  let check key label n =
    if not (Config.Validate.valid_id n) then
      error [ "user"; key ] (label ^ " must be in 0-4294967294")
  in
  let result =
    match user.mode with
    | Config.Image ->
        Option.iter
          (fun _ -> error [ "user"; "name" ] "Must be omitted in image mode")
          user.name;
        Option.iter
          (fun _ ->
            error [ "user"; "uid" ]
              "Must be omitted in image mode (a restriction beyond the v1 \
               specification)")
          user.uid;
        Option.iter
          (fun _ ->
            error [ "user"; "gid" ]
              "Must be omitted in image mode (a restriction beyond the v1 \
               specification)")
          user.gid;
        Some Image
    | Config.Keep_id -> (
        (match user.name with
        | None -> error [ "user"; "name" ] "Required for keep-id mode"
        | Some name when String.trim name = "" ->
            error [ "user"; "name" ] "Must not be blank"
        | Some _ -> ());
        let resolve_id key host = function
          | None ->
              error [ "user"; key ] "Missing effective keep-id identity";
              None
          | Some Config.Host -> Some host
          | Some (Config.Id n) ->
              check key "Container ID" n;
              Some n
        in
        match host_ids () with
        | Error message ->
            error [ "user" ] message;
            None
        | Ok host -> (
            check "uid" "Host UID" host.uid;
            check "gid" "Host GID" host.gid;
            let uid = resolve_id "uid" host.uid user.uid in
            let gid = resolve_id "gid" host.gid user.gid in
            match (user.name, uid, gid) with
            | Some name, Some uid, Some gid ->
                Some (Keep_id { name; host; container = { uid; gid } })
            | _ -> None))
  in
  match (!errors, result) with
  | [], Some result -> Ok result
  | [], None ->
      invalid_arg "User_identity: missing identity without diagnostics"
  | errors, _ -> Error (List.sort Config.Diagnostic.compare errors)
