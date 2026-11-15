type output = Capture | Inherit
type result = { status : Unix.process_status; stdout : string; stderr : string }
type error = { operation : string; message : string }

let run ?(output = Capture) argv =
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
                    let pid =
                      Unix.create_process program (Array.of_list argv)
                        Unix.stdin out_fd err_fd
                    in
                    let rec wait () =
                      try snd (Unix.waitpid [] pid)
                      with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
                    in
                    let status = wait () in
                    let read path =
                      if capture then
                        In_channel.with_open_bin path In_channel.input_all
                      else ""
                    in
                    Ok
                      { status; stdout = read out_path; stderr = read err_path }))
          with
          | Unix.Unix_error (e, operation, _) ->
              Error { operation; message = Unix.error_message e }
          | Sys_error message -> Error { operation = "capture"; message })
