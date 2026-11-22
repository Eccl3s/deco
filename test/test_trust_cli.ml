let write p s = Out_channel.with_open_bin p (fun c -> output_string c s)
let read p = In_channel.with_open_bin p In_channel.input_all

let rec cleanup p =
  if (Unix.lstat p).st_kind = Unix.S_DIR then (
    Array.iter (fun n -> cleanup (Filename.concat p n)) (Sys.readdir p);
    Unix.rmdir p)
  else Unix.unlink p

let contains s fragment =
  let rec loop i =
    i + String.length fragment <= String.length s
    && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-trust-cli" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  let temp = Unix.realpath temp in
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let root = temp ^ "/project" in
      List.iter
        (fun p -> Unix.mkdir p 0o700)
        [ root; root ^ "/.deco"; root ^ "/.deco/build"; root ^ "/child" ];
      write (root ^ "/.deco/config.toml") "project.name='example'\n";
      write (root ^ "/.deco/build/Containerfile") "FROM scratch\n";
      let state = temp ^ "/state" in
      let run ?(cwd = root ^ "/child") ?term args expected =
        let out = temp ^ "/out" and err = temp ^ "/err" in
        let fd p =
          Unix.openfile p [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let o = fd out and e = fd err in
        let i = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir cwd;
          let inherited =
            Array.to_list (Unix.environment ())
            |> List.filter (fun entry ->
                not
                  (List.exists
                     (fun prefix -> String.starts_with ~prefix entry)
                     [ "PATH="; "TERM="; "XDG_STATE_HOME=" ]))
          in
          let env =
            [ "PATH=/nonexistent"; "XDG_STATE_HOME=" ^ state ]
            @ Option.to_list (Option.map (fun term -> "TERM=" ^ term) term)
            @ inherited
          in
          Unix.dup2 i Unix.stdin;
          Unix.dup2 o Unix.stdout;
          Unix.dup2 e Unix.stderr;
          Unix.close i;
          Unix.close o;
          Unix.close e;
          Unix.execve binary
            (Array.of_list (binary :: args))
            (Array.of_list env));
        Unix.close i;
        Unix.close o;
        Unix.close e;
        let _, status = Unix.waitpid [] pid in
        let stdout = read out and stderr = read err in
        if status <> Unix.WEXITED expected then
          failwith
            (Printf.sprintf "%s: expected exit %d\nstdout: %s\nstderr: %s"
               (String.concat " " args) expected stdout stderr);
        assert (not (String.contains stdout '\027'));
        assert (not (String.contains stderr '\027'));
        (stdout, stderr)
      in
      let state_of () =
        let out, _ = run [ "trust"; "--show" ] 0 in
        List.find_map
          (fun line ->
            match String.split_on_char ':' line with
            | [ "State"; value ] -> Some (String.trim value)
            | _ -> None)
          (String.split_on_char '\n' out)
      in
      List.iter
        (fun term ->
          let out, _ = run ?term [ "trust"; "--help" ] 0 in
          assert (contains out "--revoke");
          (* Usage errors. *)
          List.iter
            (fun args ->
              let _, err = run ?term args 2 in
              assert (contains err "deco: "))
            [
              [ "trust"; "--show"; "--revoke" ];
              [ "trust"; "--show"; "--yes" ];
              [ "trust"; "--show"; "-d" ];
              [ "trust"; "--revoke"; "-y" ];
              [ "trust"; "--revoke"; "--dry-run" ];
              [ "trust"; "unexpected" ];
              [ "trust"; "--project-dir"; temp ^ "/missing" ];
            ];
          assert (not (Sys.file_exists state));
          assert (state_of () = Some "untrusted");
          (* Outside a terminal, confirmation needs --yes. *)
          let out, err = run ?term [ "trust" ] 2 in
          assert (contains out "Trust state:    untrusted");
          assert (contains err "pass --yes");
          assert (state_of () = Some "untrusted");
          let out, err = run ?term [ "trust"; "--dry-run" ] 0 in
          assert (contains out "Planned settings" && err = "");
          assert (state_of () = Some "untrusted");
          (* Approval, from a subdirectory and with --project-dir. *)
          let out, _ = run ?term [ "trust"; "--yes" ] 0 in
          assert (String.ends_with ~suffix:("Trusted " ^ root ^ "\n") out);
          assert (state_of () = Some "trusted");
          let out, _ =
            run ?term ~cwd:temp [ "trust"; "--project-dir"; root ] 0
          in
          assert (out = "Configuration is already trusted: " ^ root ^ "\n");
          let out, _ = run ?term [ "--project-dir"; root; "trust"; "-y" ] 0 in
          assert (contains out "already trusted");
          (* Changes. *)
          write (root ^ "/.deco/build/Containerfile") "FROM alpine\n";
          assert (state_of () = Some "changed");
          let out, _ = run ?term [ "trust"; "--show" ] 0 in
          assert (contains out "Changes:\n  modified  build/Containerfile\n");
          let out, _ = run ?term [ "trust"; "-d" ] 0 in
          assert (contains out "Changed since the last approval");
          let _ = run ?term [ "trust"; "-y" ] 0 in
          assert (state_of () = Some "trusted");
          write (root ^ "/.deco/build/Containerfile") "FROM scratch\n";
          assert (state_of () = Some "trusted");
          (* Invalid configuration and uncomputable digests. *)
          write (root ^ "/.deco/config.toml") "project.name=1\n";
          ignore (run ?term [ "trust"; "--yes" ] 2);
          write (root ^ "/.deco/config.toml") "project.name='example'\n";
          Unix.mkfifo (root ^ "/.deco/pipe") 0o600;
          let _, err = run ?term [ "trust"; "--yes" ] 2 in
          assert (contains err "unsupported file type");
          Unix.unlink (root ^ "/.deco/pipe");
          (* Revocation. *)
          let out, _ = run ?term [ "trust"; "--revoke" ] 0 in
          assert (out = "Trust revoked: " ^ root ^ "\n");
          let out, _ = run ?term [ "trust"; "--revoke" ] 0 in
          assert (out = "Configuration was not trusted: " ^ root ^ "\n");
          assert (state_of () = Some "untrusted");
          cleanup state)
        [ None; Some "xterm-256color" ];
      (* Approvals are only ever written under XDG_STATE_HOME. *)
      let _ = run [ "trust"; "--yes" ] 0 in
      assert (Array.length (Sys.readdir (state ^ "/deco/trust")) = 1))
