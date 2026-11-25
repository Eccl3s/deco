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
      ]
  | [ "container" ] ->
      [
        ("env_files", Strings);
        ("environment", Map);
        ("namespaces", Table (strings [ "pid"; "ipc"; "uts"; "cgroup"; "user" ]));
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

let quote s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (function
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

(* One-line TOML-style rendering of a reported value. Strings keep other
   control characters; display code escapes them for the terminal. *)
let rec render = function
  | Otoml.TomlString s -> quote s
  | Otoml.TomlInteger i -> string_of_int i
  | Otoml.TomlBoolean b -> string_of_bool b
  | Otoml.TomlArray values | Otoml.TomlTableArray values ->
      "[" ^ String.concat ", " (List.map render values) ^ "]"
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
      "{"
      ^ String.concat ", "
          (List.map (fun (key, value) -> key ^ " = " ^ render value) fields)
      ^ "}"
  | value -> Otoml.Printer.to_string value

(* Environment-variable values must never be shown. *)
let hidden = function
  | "container" :: "environment" :: _ :: _ -> true
  | _ -> false

let strip tree =
  let ignored = ref [] and errors = ref [] in
  let report path value =
    let value = if hidden path then None else Some (render value) in
    ignored := (path, value) :: !ignored
  in
  let error path message = errors := Diagnostic.{ path; message } :: !errors in
  let rec check path schema value =
    match (schema, value) with
    | String, Otoml.TomlString _
    | Integer, Otoml.TomlInteger _
    | Boolean, Otoml.TomlBoolean _ ->
        report path value
    | Strings, Otoml.TomlArray values ->
        report path value;
        List.iter
          (fun value ->
            match value with
            | Otoml.TomlString _ -> ()
            | _ -> error path "Expected an array of strings")
          values
    | (Map | Table _), (Otoml.TomlTable fields | Otoml.TomlInlineTable fields)
      ->
        if fields = [] then report path value;
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
        if rows = [] then report path value;
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
  ( supported,
    List.sort_uniq (fun (a, _) (b, _) -> compare a b) !ignored,
    !errors )
