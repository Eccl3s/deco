let version = Generated_version.value

(* Consume option values before interpreting command names or short aliases. *)
let normalize argv =
  let rec aliases = function
    | "--" :: rest -> "--" :: rest
    | (("--project-dir" | "--template" | "-t") as option) :: value :: rest ->
        option :: value :: aliases rest
    | "-h" :: rest -> "--help" :: aliases rest
    | "-V" :: rest -> "--version" :: aliases rest
    | value :: rest -> value :: aliases rest
    | [] -> []
  in
  let rec reorder prefix = function
    | "--project-dir" :: value :: rest ->
        reorder (prefix @ [ "--project-dir"; value ]) rest
    | value :: rest when String.starts_with ~prefix:"--project-dir=" value ->
        reorder (prefix @ [ value ]) rest
    | (("--help" | "--version") as value) :: rest ->
        reorder (prefix @ [ value ]) rest
    | value :: rest when String.starts_with ~prefix:"--help=" value ->
        reorder (prefix @ [ value ]) rest
    | command :: rest when command <> "" && command.[0] <> '-' ->
        (command :: prefix) @ rest
    | rest -> prefix @ rest
  in
  match Array.to_list argv with
  | [] -> argv
  | executable :: args -> Array.of_list (executable :: reorder [] (aliases args))

let command exec_arguments =
  let module Term = Cmdliner.Term in
  let module Cmd = Cmdliner.Cmd in
  let default =
    Term.(ret (const (fun _ -> `Help (`Plain, None)) $ Cli_common.project_dir))
  in
  Cmd.group ~default
    (Cmd.info "deco" ~version ~exits:Cli_common.exits
       ~doc:"Manage project-local development container configuration.")
    [
      Validate_command.command;
      Init_command.command;
      Assemble_command.command;
      Exec_command.command exec_arguments;
      Shell_command.command;
    ]

let run () =
  (* Plain output also keeps parser/help diagnostics free of terminal styling. *)
  let argv = normalize Sys.argv in
  let argv, exec_arguments =
    if Array.length argv > 1 && argv.(1) = "exec" then
      let rec split prefix = function
        | ("--project-dir" as option) :: value :: rest ->
            split (value :: option :: prefix) rest
        | "--" :: rest -> (Array.of_list (List.rev prefix), Some rest)
        | value :: rest -> split (value :: prefix) rest
        | [] -> (argv, None)
      in
      split [] (Array.to_list argv)
    else (argv, None)
  in
  let status =
    try
      match
        Cmdliner.Cmd.eval_value ~catch:false ~argv (command exec_arguments)
      with
      | Ok (`Ok status) -> status
      | Ok (`Help | `Version) -> 0
      | Error (`Parse | `Term) -> 2
      | Error `Exn -> 1
    with _ ->
      prerr_endline "deco: internal error";
      1
  in
  status
