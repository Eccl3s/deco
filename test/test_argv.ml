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
    (* -p/--project before or after the command; its value is never a command
       or an alias. *)
    ([ "-p"; "zeta"; "stop" ], [ "stop"; "-p"; "zeta" ], None);
    ([ "stop"; "-p"; "zeta" ], [ "stop"; "-p"; "zeta" ], None);
    ([ "--project"; "zeta"; "stop" ], [ "stop"; "--project"; "zeta" ], None);
    ([ "stop"; "--project"; "zeta" ], [ "stop"; "--project"; "zeta" ], None);
    ([ "--project=zeta"; "stop" ], [ "stop"; "--project=zeta" ], None);
    ([ "stop"; "--project=zeta" ], [ "stop"; "--project=zeta" ], None);
    ([ "-p"; "validate"; "stop" ], [ "stop"; "-p"; "validate" ], None);
    ([ "-p"; "exec"; "stop" ], [ "stop"; "-p"; "exec" ], None);
    ([ "stop"; "-p"; "-h" ], [ "stop"; "-p"; "-h" ], None);
    ([ "-p"; "-V"; "stop" ], [ "stop"; "-p"; "-V" ], None);
    ( [ "-p"; "zeta"; "--project-dir"; "/r"; "stop" ],
      [ "stop"; "-p"; "zeta"; "--project-dir"; "/r" ],
      None );
    (* --project= does not swallow --project-dir=. *)
    ( [ "--project-dir=/r"; "--project=zeta"; "stop" ],
      [ "stop"; "--project-dir=/r"; "--project=zeta" ],
      None );
    (* Rejection by init and list is left to Cmdliner. *)
    ([ "-p"; "zeta"; "list" ], [ "list"; "-p"; "zeta" ], None);
    ([ "init"; "-p"; "zeta" ], [ "init"; "-p"; "zeta" ], None);
    (* --format before or after the command; its value is never a command. *)
    ([ "--format"; "json"; "list" ], [ "list"; "--format"; "json" ], None);
    ([ "--format=json"; "list" ], [ "list"; "--format=json" ], None);
    ([ "list"; "--format"; "json" ], [ "list"; "--format"; "json" ], None);
    ([ "--format"; "list"; "list" ], [ "list"; "--format"; "list" ], None);
    ([ "list"; "--format"; "-h" ], [ "list"; "--format"; "-h" ], None);
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
    ( [ "-p"; "zeta"; "exec"; "--"; "ls" ],
      [ "exec"; "-p"; "zeta" ],
      Some [ "ls" ] );
    ( [ "exec"; "-p"; "zeta"; "-d"; "--"; "ls" ],
      [ "exec"; "-p"; "zeta"; "-d" ],
      Some [ "ls" ] );
    ([ "exec"; "--"; "grep"; "-p"; "x" ], [ "exec" ], Some [ "grep"; "-p"; "x" ]);
    ([ "exec"; "-p"; "--"; "--"; "x" ], [ "exec"; "-p"; "--" ], Some [ "x" ]);
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
