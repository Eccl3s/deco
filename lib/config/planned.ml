type schema =
  | String
  | Integer
  | Boolean
  | Strings
  | Map
  | Table of (string * schema) list
  | Rows of (string * schema) list

let strings names = List.map (fun key -> (key, String)) names
let integers names = List.map (fun key -> (key, Integer)) names

let registry = function
  | [] ->
      [
        ( "network",
          Table
            [
              ("mode", String);
              ("dns", Strings);
              ( "ports",
                Rows
                  (integers [ "host"; "container" ]
                  @ strings [ "protocol"; "bind" ]) );
            ] );
        ( "hooks",
          Table
            (strings [ "post_create"; "post_start"; "pre_enter"; "pre_stop" ])
        );
        ("actions", Map);
      ]
  | [ "container" ] ->
      List.map
        (fun key -> (key, Strings))
        [ "env_files"; "devices"; "cap_add"; "cap_drop"; "security_options" ]
      @ [
          ("privileged", Boolean);
          ("environment", Map);
          ( "namespaces",
            Table (strings [ "pid"; "ipc"; "uts"; "cgroup"; "user" ]) );
          ( "secrets",
            Rows
              (strings [ "name"; "type"; "target"; "mode" ]
              @ integers [ "uid"; "gid" ]) );
        ]
  | [ "mounts" ] ->
      [
        ( "volumes",
          Rows
            (strings
               [ "source"; "target"; "type"; "relabel"; "subpath"; "mode" ]
            @ integers [ "size"; "uid"; "gid"; "max" ]
            @ [ ("readonly", Boolean); ("chown", Boolean) ]) );
      ]
  | _ -> []

let strip tree =
  let ignored = ref [] and errors = ref [] in
  let report path = ignored := path :: !ignored in
  let error path message = errors := Diagnostic.{ path; message } :: !errors in
  let rec check path schema value =
    match (schema, value) with
    | String, Otoml.TomlString _
    | Integer, Otoml.TomlInteger _
    | Boolean, Otoml.TomlBoolean _ ->
        report path
    | Strings, Otoml.TomlArray values ->
        report path;
        List.iter
          (fun value ->
            match value with
            | Otoml.TomlString _ -> ()
            | _ -> error path "Expected an array of strings")
          values
    | (Map | Table _), (Otoml.TomlTable fields | Otoml.TomlInlineTable fields)
      ->
        if fields = [] then report path;
        List.iter
          (fun (key, value) ->
            match schema with
            | Map -> check (path @ [ key ]) String value
            | Table allowed -> (
                match List.assoc_opt key allowed with
                | Some schema -> check (path @ [ key ]) schema value
                | None -> error (path @ [ key ]) "Unknown or unsupported key")
            | _ -> assert false)
          fields
    | Rows fields, Otoml.TomlArray rows ->
        if rows = [] then report path;
        List.iteri
          (fun index value ->
            let entry =
              match List.rev path with
              | key :: rest ->
                  List.rev rest @ [ Printf.sprintf "%s[%d]" key index ]
              | [] -> assert false
            in
            check entry (Table fields) value)
          rows
    | _ -> error path "Incorrect type for planned setting"
  in
  let rec walk path = function
    | Otoml.TomlTable fields -> Otoml.TomlTable (filter path fields)
    | Otoml.TomlInlineTable fields -> Otoml.TomlInlineTable (filter path fields)
    | value -> value
  and filter path fields =
    List.filter_map
      (fun (key, value) ->
        match List.assoc_opt key (registry path) with
        | Some schema ->
            check (path @ [ key ]) schema value;
            None
        | None -> Some (key, walk (path @ [ key ]) value))
      fields
  in
  let supported = walk [] tree in
  (supported, List.sort_uniq compare !ignored, !errors)
