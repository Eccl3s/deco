type scope = Global | Command of string
type option_spec = { names : string list; takes_value : bool; scope : scope }
type t = { argv : string array; exec_command : string list option }

let project_dir =
  { names = [ "project-dir" ]; takes_value = true; scope = Global }

let format = { names = [ "format" ]; takes_value = true; scope = Global }

let template =
  { names = [ "t"; "template" ]; takes_value = true; scope = Command "init" }

(* Every value-taking option must be listed here, or its value may be mistaken
   for a command name or rewritten as an alias. *)
let options = [ project_dir; format; template ]
let flag name = if String.length name = 1 then "-" ^ name else "--" ^ name

let takes_value ~command token =
  List.exists
    (fun option ->
      option.takes_value
      && (match option.scope with
        | Global -> true
        | Command name -> command = Some name)
      && List.exists (fun name -> flag name = token) option.names)
    options

let alias = function "-h" -> "--help" | "-V" -> "--version" | token -> token

(* Options that may appear before the subcommand and are moved after it. *)
let global_prefix token =
  List.exists
    (fun prefix -> String.starts_with ~prefix token)
    [ "--project-dir="; "--format="; "--help=" ]

let is_command token = token <> "" && token.[0] <> '-'

let preprocess argv =
  match Array.to_list argv with
  | [] -> { argv; exec_command = None }
  | executable :: args ->
      (* Arguments after the command (or after an unrecognised option): expand
         aliases, keep option values intact, and stop at the first [--]. *)
      let rec after command acc = function
        | "--" :: rest when command = Some "exec" -> (List.rev acc, Some rest)
        | "--" :: rest -> (List.rev_append acc ("--" :: rest), None)
        | token :: value :: rest when takes_value ~command token ->
            after command (value :: token :: acc) rest
        | token :: rest -> after command (alias token :: acc) rest
        | [] -> (List.rev acc, None)
      in
      (* Arguments before the command: collect global options, then emit the
         command followed by them. *)
      let rec before collected = function
        | "--" :: _ as rest -> (List.rev_append collected rest, None)
        | token :: value :: rest when takes_value ~command:None token ->
            before (value :: token :: collected) rest
        | token :: rest when global_prefix token ->
            before (token :: collected) rest
        | (("-h" | "--help" | "-V" | "--version") as token) :: rest ->
            before (alias token :: collected) rest
        | command :: rest when is_command command ->
            let tail, exec_command = after (Some command) [] rest in
            ((command :: List.rev collected) @ tail, exec_command)
        | rest ->
            let tail, exec_command = after None [] rest in
            (List.rev_append collected tail, exec_command)
      in
      let args, exec_command = before [] args in
      { argv = Array.of_list (executable :: args); exec_command }
