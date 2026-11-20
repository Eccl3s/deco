module Argv = Argv

let version = Generated_version.value

(* Cmdliner picks ANSI styling from NO_COLOR/TERM when it initialises and never
   checks whether the output is a terminal. Strip CSI sequences (ESC [ ... final
   byte) from output written to a pipe or file. *)
let plain_formatter channel =
  let state = ref `Text in
  let output text position length =
    let buffer = Buffer.create length in
    for i = position to position + length - 1 do
      match (!state, text.[i]) with
      | `Text, '\027' -> state := `Escape
      | `Text, c -> Buffer.add_char buffer c
      | `Escape, '[' -> state := `Csi
      | `Escape, c ->
          state := `Text;
          Buffer.add_char buffer c
      | `Csi, '\x40' .. '\x7e' -> state := `Text
      | `Csi, _ -> ()
    done;
    Out_channel.output_string channel (Buffer.contents buffer)
  in
  Format.make_formatter output (fun () -> Out_channel.flush channel)

let formatter fd channel default =
  if Unix.isatty fd then default else plain_formatter channel

let command exec_arguments =
  let module Term = Cmdliner.Term in
  let module Cmd = Cmdliner.Cmd in
  let default =
    Term.(ret (const (fun _ -> `Help (`Plain, None)) $ Cli_common.project))
  in
  Cmd.group ~default
    (Cmd.info "deco" ~version ~exits:Cli_common.exits
       ~doc:"Manage project-local development container configuration.")
    [
      Validate_command.command;
      Init_command.command;
      Assemble_command.command;
      Refresh_command.command;
      Exec_command.command exec_arguments;
      Shell_command.command;
      Stop_command.command;
      Remove_command.command;
      List_command.command;
    ]

let run () =
  let { Argv.argv; exec_command = exec_arguments } = Argv.preprocess Sys.argv in
  let help = formatter Unix.stdout stdout Format.std_formatter
  and err = formatter Unix.stderr stderr Format.err_formatter in
  (* With TERM set, Cmdliner's default help format runs a pager even when
     stdout is not a terminal; hide TERM so piped help is printed as plain text. *)
  let env =
    if Unix.isatty Unix.stdout then Sys.getenv_opt
    else function "TERM" -> None | name -> Sys.getenv_opt name
  in
  let status =
    try
      match
        Cmdliner.Cmd.eval_value ~help ~err ~env ~catch:false ~argv
          (command exec_arguments)
      with
      | Ok (`Ok status) -> status
      | Ok (`Help | `Version) -> 0
      | Error (`Parse | `Term) -> 2
      | Error `Exn -> 1
    with _ ->
      prerr_endline "deco: internal error";
      1
  in
  Format.pp_print_flush help ();
  Format.pp_print_flush err ();
  status
