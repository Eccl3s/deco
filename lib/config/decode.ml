open Config_types

type error =
  | Syntax_error of { message : string; location : (int * int) option }
  | Schema_error of Diagnostic.t

let error_to_string = function
  | Syntax_error { message; location = None } -> message
  | Syntax_error { message; location = Some (line, column) } ->
      Printf.sprintf "Line %d, column %d: %s" line column message
  | Schema_error diagnostic -> Diagnostic.to_string diagnostic

let parse input =
  try Ok (Otoml.Parser.from_string input) with
  | Otoml.Parse_error (location, message) ->
      Error [ Syntax_error { message; location } ]
  | Otoml.Duplicate_key message ->
      Error [ Syntax_error { message; location = None } ]
  | Failure message when message = "int_of_string" ->
      Error
        [
          Syntax_error
            {
              message = "Integer exceeds the supported OCaml int range";
              location = None;
            };
        ]
  | Failure message ->
      Error
        [
          Syntax_error
            {
              message = "TOML parser could not decode a value: " ^ message;
              location = None;
            };
        ]

let from_string_with_ignored input =
  let ignored = ref [] in
  let errors = ref [] in
  let sorted_errors () =
    List.map
      (fun diagnostic -> Schema_error diagnostic)
      (List.sort Diagnostic.compare !errors)
  in
  let error path message = errors := Diagnostic.{ path; message } :: !errors in
  let string path = function
    | Otoml.TomlString s -> Some s
    | _ ->
        error path "Expected a string";
        None
  in
  let boolean path = function
    | Otoml.TomlBoolean b -> Some b
    | _ ->
        error path "Expected a boolean";
        None
  in
  let strings path = function
    | Otoml.TomlArray values ->
        let decoded =
          List.filter_map
            (function Otoml.TomlString s -> Some s | _ -> None)
            values
        in
        if List.length decoded = List.length values then Some decoded
        else (
          error path "Expected an array of strings";
          None)
    | _ ->
        error path "Expected an array of strings";
        None
  in
  let enum choices path value =
    match string path value with
    | None -> None
    | Some s -> (
        match List.assoc_opt s choices with
        | Some value -> Some value
        | None ->
            error path
              (Printf.sprintf "Unsupported value %S (expected one of: %s)" s
                 (String.concat ", "
                    (List.map (fun (key, _) -> Printf.sprintf "%S" key) choices)));
            None)
  in
  let id path = function
    | Otoml.TomlInteger n -> Some (Id n)
    | Otoml.TomlString "host" -> Some Host
    | _ ->
        error path "Expected an integer or \"host\"";
        None
  in
  let table path allowed = function
    | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
        List.iter
          (fun (key, _) ->
            if not (List.mem key allowed) then
              error (path @ [ key ]) "Unknown or unsupported key")
          fields;
        Some fields
    | _ ->
        error path "Expected a table";
        None
  in
  let field path fields key decode =
    Option.bind (List.assoc_opt key fields) (decode (path @ [ key ]))
  in
  let required path fields key decode =
    match List.assoc_opt key fields with
    | None ->
        error (path @ [ key ]) "Required value is missing";
        None
    | Some v -> decode (path @ [ key ]) v
  in
  let record allowed make path value =
    Option.map (make path) (table path allowed value)
  in
  let required_record allowed make path value =
    Option.bind (table path allowed value) (make path)
  in
  let project =
    required_record [ "name"; "description" ] (fun p f ->
        let name = required p f "name" string in
        let description = field p f "description" string in
        Option.map (fun name -> { name; description }) name)
  in
  let image =
    record [ "name"; "tag" ] (fun p f ->
        { name = field p f "name" string; tag = field p f "tag" string })
  in
  let args path = function
    | Otoml.TomlTable f | Otoml.TomlInlineTable f ->
        Some
          (List.filter_map
             (fun (k, v) ->
               Option.map (fun v -> (k, v)) (string (path @ [ k ]) v))
             f)
    | _ ->
        error path "Expected a table";
        None
  in
  let build =
    record [ "context"; "containerfile"; "target"; "pull"; "no_cache"; "args" ]
      (fun p f ->
        {
          context = field p f "context" string;
          containerfile = field p f "containerfile" string;
          target = field p f "target" string;
          pull = field p f "pull" boolean;
          no_cache = field p f "no_cache" boolean;
          args = Option.value ~default:[] (field p f "args" args);
        })
  in
  let user =
    record [ "name"; "mode"; "uid"; "gid" ] (fun p f ->
        {
          name = field p f "name" string;
          mode =
            field p f "mode" (enum [ ("keep-id", Keep_id); ("image", Image) ]);
          uid = field p f "uid" id;
          gid = field p f "gid" id;
        })
  in
  let container =
    record
      [
        "name";
        "workdir";
        "shell";
        "privileged";
        "devices";
        "cap_add";
        "cap_drop";
        "security_options";
        "env_files";
        "environment";
      ] (fun p f ->
        {
          name = field p f "name" string;
          workdir = field p f "workdir" string;
          shell = field p f "shell" string;
          privileged = field p f "privileged" boolean;
          devices = field p f "devices" strings;
          cap_add = field p f "cap_add" strings;
          cap_drop = field p f "cap_drop" strings;
          security_options = field p f "security_options" strings;
          env_files = field p f "env_files" strings;
          environment = field p f "environment" args;
        })
  in
  let workspace =
    required_record [ "source"; "target"; "relabel" ] (fun p f ->
        let target = required p f "target" string in
        let source = field p f "source" string in
        let relabel =
          field p f "relabel"
            (enum
               [
                 ("shared", Shared); ("private", Private); ("none", No_relabel);
               ])
        in
        Option.map (fun target -> { source; target; relabel }) target)
  in
  let mounts =
    record [ "workspace" ] (fun p f ->
        { workspace = field p f "workspace" workspace })
  in
  let hooks =
    record [ "post_create"; "post_start"; "pre_enter"; "pre_stop" ] (fun p f ->
        {
          post_create = field p f "post_create" string;
          post_start = field p f "post_start" string;
          pre_enter = field p f "pre_enter" string;
          pre_stop = field p f "pre_stop" string;
        })
  in
  match parse input with
  | Error errors -> Error errors
  | Ok tree -> (
      let tree, planned, planned_errors = Planned.strip tree in
      ignored := List.map fst planned;
      errors := planned_errors @ !errors;
      match
        table []
          [
            "project";
            "image";
            "build";
            "user";
            "container";
            "mounts";
            "hooks";
            "actions";
          ]
          tree
      with
      | None -> Error (sorted_errors ())
      | Some fields -> (
          let project = required [] fields "project" project in
          let image = field [] fields "image" image in
          let build = field [] fields "build" build in
          let user = field [] fields "user" user in
          let container = field [] fields "container" container in
          let mounts = field [] fields "mounts" mounts in
          let hooks = field [] fields "hooks" hooks in
          let actions = field [] fields "actions" args in
          match (!errors, project) with
          | [], Some project ->
              Ok
                ( {
                    project;
                    image;
                    build;
                    user;
                    container;
                    mounts;
                    hooks;
                    actions;
                  },
                  !ignored )
          | [], None ->
              invalid_arg "Config.Decode: missing project without schema error"
          | _ -> Error (sorted_errors ())))

let from_string input = Result.map fst (from_string_with_ignored input)

let planned_settings input =
  match parse input with
  | Error _ -> []
  | Ok tree ->
      let _, planned, _ = Planned.strip tree in
      planned

let project_name input =
  match parse input with
  | Error _ -> None
  | Ok toml -> (
      match Otoml.find_opt toml Fun.id [ "project"; "name" ] with
      | Some (Otoml.TomlString name) -> Some name
      | _ -> None)
