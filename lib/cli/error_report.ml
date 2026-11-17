let pp_config_error formatter error =
  let diagnostic (value : Config.Diagnostic.t) =
    ( Config.Diagnostic.format_path value.Config.Diagnostic.path,
      value.Config.Diagnostic.message )
  in
  let heading, path, rows =
    match error with
    | Deco.Config_loader.Read_error { config_path; message } ->
        ("Cannot read configuration", config_path, [ ("", message) ])
    | Deco.Config_loader.Decode_errors { config_path; errors } ->
        let row = function
          | Config.Decode.Schema_error value -> diagnostic value
          | Config.Decode.Syntax_error { message; location } ->
              let label =
                match location with
                | None -> ""
                | Some (line, column) ->
                    Printf.sprintf "Line %d, column %d" line column
              in
              (label, message)
        in
        ("Invalid configuration", config_path, List.map row errors)
    | Deco.Config_loader.Validation_errors { config_path; errors } ->
        ("Invalid configuration", config_path, List.map diagnostic errors)
    | Deco.Config_loader.Host_path_errors { config_path; errors } ->
        ("Host path check failed", config_path, List.map diagnostic errors)
    | Deco.Config_loader.Identity_errors { config_path; errors } ->
        ( "Could not resolve user identity",
          config_path,
          List.map diagnostic errors )
  in
  let width =
    List.fold_left
      (fun width (label, _) -> max width (String.length label))
      0 rows
  in
  Format.fprintf formatter "%s: %s\n\n" heading path;
  let lines =
    List.concat_map
      (fun (label, message) ->
        let prefix =
          if width = 0 then "  " else Printf.sprintf "  %-*s  " width label
        in
        match String.split_on_char '\n' message with
        | [] -> []
        | first :: rest ->
            (prefix ^ first)
            :: List.map
                 (fun line ->
                   String.make (if width = 0 then 2 else width + 4) ' ' ^ line)
                 rest)
      rows
  in
  Format.pp_print_string formatter (String.concat "\n" lines)
