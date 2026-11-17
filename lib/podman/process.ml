type output = Capture | Inherit
type result = { status : Unix.process_status; stdout : string; stderr : string }
type error = { operation : string; message : string }

let run ?(output = Capture) ?poll ?(forward_signals = false) argv =
  match argv with
  | [] -> Error { operation = "launch"; message = "Empty argument vector" }
  | program :: _ ->
      let files = ref [] in
      let cleanup () =
        List.iter (fun p -> try Sys.remove p with Sys_error _ -> ()) !files
      in
      let temporary () =
        let path = Filename.temp_file "deco-process-" ".out" in
        files := path :: !files;
        path
      in
      Fun.protect ~finally:cleanup (fun () ->
          try
            let capture =
              match output with Capture -> true | Inherit -> false
            in
            let out_path = if capture then temporary () else "" in
            let err_path = if capture then temporary () else "" in
            let out_fd =
              if capture then
                Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0o600
              else Unix.stdout
            in
            Fun.protect
              ~finally:(fun () -> if capture then Unix.close out_fd)
              (fun () ->
                let err_fd =
                  if capture then
                    Unix.openfile err_path
                      [ Unix.O_WRONLY; Unix.O_CLOEXEC ]
                      0o600
                  else Unix.stderr
                in
                Fun.protect
                  ~finally:(fun () -> if capture then Unix.close err_fd)
                  (fun () ->
                    let child = ref None and pending = ref [] in
                    let relay signal =
                      match !child with
                      | None -> pending := signal :: !pending
                      | Some pid -> (
                          try Unix.kill pid signal
                          with Unix.Unix_error (Unix.ESRCH, _, _) -> ())
                    in
                    let handlers =
                      if forward_signals then
                        List.map
                          (fun signal ->
                            (signal, Sys.signal signal (Sys.Signal_handle relay)))
                          [ Sys.sigint; Sys.sigterm ]
                      else []
                    in
                    Fun.protect
                      ~finally:(fun () ->
                        List.iter
                          (fun (signal, handler) ->
                            Sys.set_signal signal handler)
                          handlers)
                      (fun () ->
                        let pid =
                          Unix.create_process program (Array.of_list argv)
                            Unix.stdin out_fd err_fd
                        in
                        child := Some pid;
                        List.iter relay (List.rev !pending);
                        let rec wait () =
                          try
                            match poll with
                            | None -> snd (Unix.waitpid [] pid)
                            | Some tick ->
                                tick ();
                                let child, status =
                                  Unix.waitpid [ Unix.WNOHANG ] pid
                                in
                                if child = 0 then (
                                  ignore (Unix.select [] [] [] 0.1);
                                  wait ())
                                else status
                          with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
                        in
                        let status = wait () in
                        let read path =
                          if capture then
                            In_channel.with_open_bin path In_channel.input_all
                          else ""
                        in
                        Ok
                          {
                            status;
                            stdout = read out_path;
                            stderr = read err_path;
                          })))
          with
          | Unix.Unix_error (e, operation, _) ->
              Error { operation; message = Unix.error_message e }
          | Sys_error message -> Error { operation = "capture"; message })

let run_stream ~on_chunk ~poll argv =
  match argv with
  | [] -> Error { operation = "launch"; message = "Empty argument vector" }
  | program :: _ ->
      let rd, wr = Unix.pipe ~cloexec:true () in
      let input =
        Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
      in
      Fun.protect
        ~finally:(fun () ->
          Unix.close rd;
          Unix.close input)
        (fun () ->
          try
            let pid =
              Fun.protect
                ~finally:(fun () -> Unix.close wr)
                (fun () ->
                  Unix.create_process program (Array.of_list argv) input wr wr)
            in
            let buffer = Bytes.create 8192 in
            let status = ref None and deadline = ref None and eof = ref false in
            let rec check_child () =
              if !status = None then
                try
                  let child, result = Unix.waitpid [ Unix.WNOHANG ] pid in
                  if child <> 0 then (
                    status := Some result;
                    deadline := Some (Unix.gettimeofday () +. 1.))
                with Unix.Unix_error (Unix.EINTR, _, _) -> check_child ()
            in
            let rec drain () =
              check_child ();
              poll ();
              let remaining =
                match !deadline with
                | None -> 0.1
                | Some until -> min 0.1 (max 0. (until -. Unix.gettimeofday ()))
              in
              if !status <> None && (!eof || remaining = 0.) then ()
              else
                let ready, _, _ =
                  try Unix.select (if !eof then [] else [ rd ]) [] [] remaining
                  with Unix.Unix_error (Unix.EINTR, _, _) -> ([], [], [])
                in
                (if ready <> [] then
                   let n =
                     try Some (Unix.read rd buffer 0 (Bytes.length buffer))
                     with Unix.Unix_error (Unix.EINTR, _, _) -> None
                   in
                   match n with
                   | Some 0 -> eof := true
                   | Some n -> on_chunk (Bytes.sub_string buffer 0 n)
                   | None -> ());
                drain ()
            in
            let rec reap () =
              if !status = None then
                try
                  let _, result = Unix.waitpid [] pid in
                  status := Some result
                with Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
            in
            (try drain ()
             with e ->
               (try check_child () with Unix.Unix_error _ -> ());
               if !status = None then (
                 (try Unix.kill pid Sys.sigterm
                  with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
                 try reap () with Unix.Unix_error _ -> ());
               raise e);
            Ok { status = Option.get !status; stdout = ""; stderr = "" }
          with Unix.Unix_error (e, operation, _) ->
            Error { operation; message = Unix.error_message e })
