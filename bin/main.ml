let default_config = ".deco/config.toml"

let read_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let contents = really_input_string ic len in
  close_in ic;
  contents

let () =
  let path =
    if Array.length Sys.argv >= 2 then Sys.argv.(1) else default_config
  in
  let source =
    try read_file path with
    | Sys_error msg ->
        Printf.eprintf "deco: %s\n" msg;
        exit 1
  in
  match Toml.parse source with
  | config -> print_string (Toml.to_string config)
  | exception Toml.Parse_error (msg, line, col) ->
      Printf.eprintf "%s:%d:%d: parse error: %s\n" path line col msg;
      exit 1
