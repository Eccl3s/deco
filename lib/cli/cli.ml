module Argv = Argv

let version = Generated_version.value

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
      Stop_command.command;
      Remove_command.command;
    ]

let run () =
  let { Argv.argv; exec_command = exec_arguments } = Argv.preprocess Sys.argv in
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
