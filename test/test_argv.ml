(* Table-driven tests for [Cli.Argv.preprocess]. Each row is the arguments after
   the executable name, the expected Cmdliner arguments, and the expected
   [deco exec] command. *)

let cases =
  [
    (* No arguments or separator only. *)
    ([], [], None);
    ([ "--" ], [ "--" ], None);
    ([ "" ], [ "" ], None);
    (* --project-dir before or after the command. *)
    ( [ "--project-dir"; "/r"; "validate" ],
      [ "validate"; "--project-dir"; "/r" ],
      None );
    ( [ "validate"; "--project-dir"; "/r" ],
      [ "validate"; "--project-dir"; "/r" ],
      None );
    ( [ "validate"; "--project-dir=/r" ],
      [ "validate"; "--project-dir=/r" ],
      None );
    ( [ "--project-dir=/r"; "validate" ],
      [ "validate"; "--project-dir=/r" ],
      None );
    ( [ "validate"; "--project-dir"; "/r"; "--project-dir"; "/r" ],
      [ "validate"; "--project-dir"; "/r"; "--project-dir"; "/r" ],
      None );
    (* An option value is never a command name. *)
    ( [ "--project-dir"; "validate"; "validate" ],
      [ "validate"; "--project-dir"; "validate" ],
      None );
    ( [ "--project-dir"; "exec"; "validate" ],
      [ "validate"; "--project-dir"; "exec" ],
      None );
    (* Short aliases for help and version. *)
    ([ "-h" ], [ "--help" ], None);
    ([ "-V" ], [ "--version" ], None);
    ([ "-h"; "validate" ], [ "validate"; "--help" ], None);
    ([ "validate"; "-V" ], [ "validate"; "--version" ], None);
    ([ "--help"; "exec" ], [ "exec"; "--help" ], None);
    ([ "--help=plain"; "validate" ], [ "validate"; "--help=plain" ], None);
    ( [ "--project-dir"; "/r"; "validate"; "-h" ],
      [ "validate"; "--project-dir"; "/r"; "--help" ],
      None );
    (* An alias is not expanded after -- or as an option value. *)
    ([ "validate"; "--"; "-h" ], [ "validate"; "--"; "-h" ], None);
    ( [ "validate"; "--project-dir"; "-V" ],
      [ "validate"; "--project-dir"; "-V" ],
      None );
    ([ "init"; "-t"; "-h" ], [ "init"; "-t"; "-h" ], None);
    ([ "init"; "--template"; "-V" ], [ "init"; "--template"; "-V" ], None);
    (* -t takes a value only under init. *)
    ([ "shell"; "-t"; "-h" ], [ "shell"; "-t"; "--help" ], None);
    (* Unknown options before the command stop reordering. *)
    ([ "-d"; "exec"; "--"; "true" ], [ "-d"; "exec"; "--"; "true" ], None);
    (* deco exec: everything after the first -- is the container command. *)
    ([ "exec" ], [ "exec" ], None);
    ([ "exec"; "echo" ], [ "exec"; "echo" ], None);
    ([ "exec"; "--" ], [ "exec" ], Some []);
    ( [ "exec"; "-d"; "--"; "ls"; "--project-dir"; "/etc"; "-h" ],
      [ "exec"; "-d" ],
      Some [ "ls"; "--project-dir"; "/etc"; "-h" ] );
    ( [ "--project-dir"; "."; "exec"; "-d"; "--"; "true" ],
      [ "exec"; "--project-dir"; "."; "-d" ],
      Some [ "true" ] );
    ( [ "exec"; "--project-dir=."; "-d"; "--"; "true" ],
      [ "exec"; "--project-dir=."; "-d" ],
      Some [ "true" ] );
    ( [ "exec"; "--"; "/bin/printf"; "%s"; "--project-dir" ],
      [ "exec" ],
      Some [ "/bin/printf"; "%s"; "--project-dir" ] );
    ( [ "exec"; "-d"; "--"; "echo"; "-h"; "" ],
      [ "exec"; "-d" ],
      Some [ "echo"; "-h"; "" ] );
    ([ "exec"; "-h"; "--"; "x" ], [ "exec"; "--help" ], Some [ "x" ]);
    ( [ "exec"; "--project-dir"; "--"; "--"; "x" ],
      [ "exec"; "--project-dir"; "--" ],
      Some [ "x" ] );
  ]

let show = function
  | None -> "None"
  | Some xs ->
      "Some [" ^ String.concat "; " (List.map (Printf.sprintf "%S") xs) ^ "]"

let () =
  let failures =
    List.filter_map
      (fun (input, expected_argv, expected_exec) ->
        let { Cli.Argv.argv; exec_command } =
          Cli.Argv.preprocess (Array.of_list ("deco" :: input))
        in
        let actual_argv = List.tl (Array.to_list argv) in
        if
          Array.length argv > 0
          && argv.(0) = "deco"
          && actual_argv = expected_argv
          && exec_command = expected_exec
        then None
        else
          Some
            (Printf.sprintf "input:    %s\nexpected: %s, %s\nactual:   %s, %s\n"
               (show (Some input))
               (show (Some expected_argv))
               (show expected_exec) (show (Some actual_argv))
               (show exec_command)))
      cases
  in
  List.iter prerr_string failures;
  if failures <> [] then exit 1
