open Deco

let () =
  if Array.length Sys.argv > 1 then
    match Sys.argv.(1) with
    | "echo" -> print_string Sys.argv.(2)
    | "large" ->
        for _ = 1 to 10000 do
          output_string stdout "0123456789";
          output_string stderr "abcdefghij"
        done
    | "exit" -> exit 7
    | "signal" -> Unix.kill (Unix.getpid ()) Sys.sigterm
    | "hold-silent" | "hold-writing" | "early-eof" | "barrier" -> ()
    | _ -> assert false
  else
    let run args =
      match Process.run (Sys.executable_name :: args) with
      | Ok r -> r
      | Error e -> failwith e.message
    in
    let literal = "hello ; $(echo bad) ' \" world" in
    assert ((run [ "echo"; literal ]).stdout = literal);
    let r = run [ "large" ] in
    assert (String.length r.stdout = 100000 && String.length r.stderr = 100000);
    assert ((run [ "exit" ]).status = Unix.WEXITED 7);
    assert ((run [ "signal" ]).status = Unix.WSIGNALED Sys.sigterm);
    assert (Result.is_error (Process.run [ "/nonexistent/deco-test-command" ]));
    assert (Result.is_error (Process.run []));
    assert (
      match Process.run ~output:Inherit [ Sys.executable_name; "echo"; "" ] with
      | Ok r -> r.status = Unix.WEXITED 0 && r.stdout = ""
      | _ -> false)

let () =
  if Array.length Sys.argv = 1 then (
    let log = Buffer.create 32 in
    let result =
      Process.run_stream ~on_chunk:(Buffer.add_string log)
        ~poll:(fun () -> ())
        [ Sys.executable_name; "large" ]
    in
    assert (match result with Ok r -> r.status = Unix.WEXITED 0 | _ -> false);
    assert (Buffer.length log = 200000))

let () =
  if Array.length Sys.argv = 1 then (
    let polls = ref 0 in
    let result =
      Process.run
        ~poll:(fun () -> incr polls)
        [ Sys.executable_name; "echo"; "captured output" ]
    in
    assert (!polls > 0);
    assert (
      match result with
      | Ok r ->
          r.status = Unix.WEXITED 0
          && r.stdout = "captured output"
          && r.stderr = ""
      | Error _ -> false))

(* Run the pipe-holder regressions under a separate watchdog. *)
let () =
  if Array.length Sys.argv > 1 then
    match Sys.argv.(1) with
    | "hold-silent" | "hold-writing" ->
        let child = Unix.fork () in
        if child = 0 then (
          Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
          let until = Unix.gettimeofday () +. 10. in
          (try
             while Unix.gettimeofday () < until do
               if Sys.argv.(1) = "hold-writing" then (
                 output_string stdout "descendant\n";
                 flush stdout);
               ignore (Unix.select [] [] [] 0.01)
             done
           with Sys_error _ -> ());
          Unix._exit 0)
        else (
          Out_channel.with_open_bin Sys.argv.(2) (fun ch ->
              Printf.fprintf ch "%d" child);
          exit 7)
    | "early-eof" ->
        Unix.close Unix.stdout;
        Unix.close Unix.stderr;
        ignore (Unix.select [] [] [] 0.2);
        Unix._exit 7
    | _ -> ()
  else (
    List.iter
      (fun mode ->
        let pidfile = Filename.temp_file "deco-descendant-" ".pid" in
        let worker = Unix.fork () in
        (if worker = 0 then
           let result =
             Process.run_stream
               ~on_chunk:(fun _ -> ())
               ~poll:(fun () -> ())
               [ Sys.executable_name; mode; pidfile ]
           in
           Unix._exit
             (match result with
             | Ok r when r.status = Unix.WEXITED 7 -> 0
             | _ -> 1));
        Fun.protect
          ~finally:(fun () ->
            let contents =
              In_channel.with_open_bin pidfile In_channel.input_all
            in
            (match int_of_string_opt contents with
            | Some pid -> (
                try Unix.kill pid Sys.sigterm
                with Unix.Unix_error (Unix.ESRCH, _, _) -> ())
            | None -> ());
            Sys.remove pidfile)
          (fun () ->
            let until = Unix.gettimeofday () +. 5. in
            let rec wait () =
              let pid, status = Unix.waitpid [ Unix.WNOHANG ] worker in
              if pid <> 0 then assert (status = Unix.WEXITED 0)
              else if Unix.gettimeofday () > until then (
                Unix.kill worker Sys.sigkill;
                ignore (Unix.waitpid [] worker);
                failwith "Streaming watchdog expired")
              else (
                ignore (Unix.select [] [] [] 0.02);
                wait ())
            in
            wait ()))
      [ "hold-silent"; "hold-writing"; "early-eof" ];
    List.iter
      (fun mode ->
        let r =
          Process.run_stream
            ~on_chunk:(fun _ -> ())
            ~poll:(fun () -> ())
            [ Sys.executable_name; mode ]
        in
        assert (
          match r with
          | Ok r -> (
              match mode with
              | "exit" -> r.status = Unix.WEXITED 7
              | _ -> r.status = Unix.WSIGNALED Sys.sigterm)
          | _ -> false))
      [ "exit"; "signal" ];
    let raised =
      try
        ignore
          (Process.run_stream
             ~on_chunk:(fun _ -> failwith "callback")
             ~poll:(fun () -> ())
             [ Sys.executable_name; "echo"; "output" ]);
        false
      with Failure message -> message = "callback"
    in
    assert raised)

let () =
  if Array.length Sys.argv = 1 then
    List.iter
      (fun signal ->
        let previous = Sys.signal signal Sys.Signal_ignore in
        Fun.protect
          ~finally:(fun () -> Sys.set_signal signal previous)
          (fun () ->
            let sent = ref false in
            let result =
              Process.run ~forward_signals:true
                ~poll:(fun () ->
                  if not !sent then (
                    sent := true;
                    Unix.kill (Unix.getpid ()) signal))
                [ "/bin/sleep"; "10" ]
            in
            assert (
              match result with
              | Ok r -> r.status = Unix.WSIGNALED signal
              | Error _ -> false);
            let restored = Sys.signal signal Sys.Signal_ignore in
            assert (restored = Sys.Signal_ignore)))
      [ Sys.sigint; Sys.sigterm ]

let () =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = "barrier" then (
    Out_channel.with_open_bin Sys.argv.(2) (fun ch -> output_string ch "ready");
    let deadline = Unix.gettimeofday () +. 2. in
    while
      (not (Sys.file_exists Sys.argv.(3))) && Unix.gettimeofday () < deadline
    do
      ignore (Unix.select [] [] [] 0.005)
    done;
    if not (Sys.file_exists Sys.argv.(3)) then exit 99;
    print_string Sys.argv.(4))
  else if Array.length Sys.argv = 1 then (
    let root = Filename.temp_file "deco-batch-barrier" "" in
    Unix.unlink root;
    Unix.mkdir root 0o700;
    Fun.protect
      ~finally:(fun () ->
        Array.iter
          (fun name -> Unix.unlink (Filename.concat root name))
          (Sys.readdir root);
        Unix.rmdir root)
      (fun () ->
        let a = Filename.concat root "a" and b = Filename.concat root "b" in
        let results =
          Process.run_many
            [
              [ Sys.executable_name; "barrier"; a; b; "first" ];
              [ Sys.executable_name; "barrier"; b; a; "second" ];
              [ "/nonexistent/deco-batch-test" ];
              [ Sys.executable_name; "large" ];
            ]
        in
        match results with
        | [ Ok first; Ok second; Error _; Ok large ] ->
            assert (first.status = Unix.WEXITED 0 && first.stdout = "first");
            assert (second.status = Unix.WEXITED 0 && second.stdout = "second");
            assert (
              String.length large.stdout = 100000
              && String.length large.stderr = 100000)
        | _ -> assert false);
    let sent = ref false in
    let results =
      Process.run_many ~forward_signals:true
        ~poll:(fun () ->
          if not !sent then (
            sent := true;
            Unix.kill (Unix.getpid ()) Sys.sigterm))
        [ [ "/bin/sleep"; "2" ]; [ "/bin/sleep"; "2" ] ]
    in
    List.iter
      (function
        | Ok r -> assert (r.Process.status = Unix.WSIGNALED Sys.sigterm)
        | Error _ -> assert false)
      results;
    let raised =
      try
        ignore
          (Process.run_many
             ~poll:(fun () -> failwith "batch poll")
             [ [ "/bin/sleep"; "2" ] ]);
        false
      with Failure message -> message = "batch poll"
    in
    assert raised;
    assert (
      try
        ignore (Unix.waitpid [ Unix.WNOHANG ] (-1));
        false
      with Unix.Unix_error (Unix.ECHILD, _, _) -> true))
