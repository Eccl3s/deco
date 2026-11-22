let write p s = Out_channel.with_open_bin p (fun c -> output_string c s)
let read p = In_channel.with_open_bin p In_channel.input_all

let rec cleanup p =
  if (Unix.lstat p).st_kind = Unix.S_DIR then (
    Array.iter (fun n -> cleanup (Filename.concat p n)) (Sys.readdir p);
    Unix.rmdir p)
  else Unix.unlink p

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-assemble-cli" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let mkdir p = Unix.mkdir (temp ^ p) 0o700 in
      mkdir "/.deco";
      mkdir "/.deco/build";
      mkdir "/fake";
      mkdir "/child";
      let config = temp ^ "/.deco/config.toml" in
      write config "[project]\nname='example'\n";
      write (temp ^ "/.deco/build/Containerfile") "FROM scratch\n";
      let log = temp ^ "/calls" in
      let fake = temp ^ "/fake/podman" in
      let run ?(path = temp ^ "/fake") args expected =
        let out = temp ^ "/out" and err = temp ^ "/err" in
        let fd p =
          Unix.openfile p [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let o = fd out and e = fd err in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir (temp ^ "/child");
          Unix.putenv "PATH" path;
          Unix.putenv "XDG_STATE_HOME" (temp ^ "/state");
          Unix.putenv "DECO_TEST_LOG" log;
          Unix.dup2 o Unix.stdout;
          Unix.dup2 e Unix.stderr;
          Unix.close o;
          Unix.close e;
          Unix.execv binary (Array.of_list (binary :: args)));
        Unix.close o;
        Unix.close e;
        let _, status = Unix.waitpid [] pid in
        if status <> Unix.WEXITED expected then
          failwith (In_channel.with_open_bin err In_channel.input_all);
        ( In_channel.with_open_bin out In_channel.input_all,
          In_channel.with_open_bin err In_channel.input_all )
      in
      let contains s fragment =
        let rec loop i =
          i + String.length fragment <= String.length s
          && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
        in
        loop 0
      in
      write fake "#!/bin/sh\nprintf called >> \"$DECO_TEST_LOG\"\nexit 125\n";
      Unix.chmod fake 0o700;
      (* Trust is required before Podman is used; a dry run only notes it. *)
      let out, err = run [ "stop" ] 5 in
      assert (out = "" && contains err "deco: configuration for ");
      assert (
        contains err
          " is not trusted\nRun 'deco trust' to review and approve it.\n");
      assert (
        contains err
          "Or run 'deco stop --no-hooks' to stop without running hooks.\n");
      assert (not (Sys.file_exists log));
      let _, err = run [ "stop"; "-d" ] 0 in
      assert (
        err
        = "Note: configuration is not trusted; 'deco stop' would fail with \
           exit code 5.\n");
      assert (not (Sys.file_exists log));
      (* --no-hooks waives trust with a warning and reaches Podman, which the
         fake reports as unusable. *)
      let warning =
        "deco: proceeding without hooks for configuration that is not trusted \
         (untrusted): "
      in
      let out, err = run [ "stop"; "--no-hooks" ] 3 in
      assert (out = "" && String.starts_with ~prefix:warning err);
      assert (contains err "; pre_stop is skipped.\n");
      assert (Sys.file_exists log);
      Unix.unlink log;
      let _, err = run [ "stop"; "--no-hooks"; "-d" ] 0 in
      assert (
        String.starts_with ~prefix:warning err
        && not (contains err "would fail"));
      assert (not (Sys.file_exists log));
      ignore (run [ "start"; "--no-hooks" ] 2);
      ignore (run [ "trust"; "--yes" ] 0);
      (* Trusted: --no-hooks changes nothing visible. *)
      let _, err = run [ "stop"; "--no-hooks"; "-d" ] 0 in
      assert (err = "");
      ignore (run [ "stop"; "--help" ] 0);
      ignore (run [ "stop"; "unexpected" ] 2);
      ignore (run [ "stop"; "--force" ] 2);
      ignore (run [ "stop"; "--project-dir"; "/nonexistent/deco" ] 2);
      assert (not (Sys.file_exists log));
      List.iter
        (fun args ->
          let out, err = run ~path:"/nonexistent" args 0 in
          assert (contains out "Stop preview" && err = ""))
        [
          [ "stop"; "-d" ];
          [ "stop"; "--project-dir"; temp; "--dry-run" ];
          [ "--project-dir"; temp; "stop"; "-d" ];
        ];
      assert (not (Sys.file_exists log));
      ignore (run [ "stop" ] 3);
      List.iter
        (fun (mode, expected, output) ->
          let labels =
            Printf.sprintf
              {|"dev.deco.managed":"true","dev.deco.project":"%s","dev.deco.project-root":%s|}
              (if mode = "owner" then "foreign" else "example")
              (Yojson.Basic.to_string (`String temp))
          in
          let fixture state =
            Printf.sprintf
              {|[{"Id":"cid","Image":"unrelated","State":{"Status":"%s"},"Config":{"Labels":{%s}},"HostConfig":{"UsernsMode":""},"Mounts":[]}]|}
              state labels
          in
          let stopped = temp ^ "/stopped" in
          (try Unix.unlink stopped with Unix.Unix_error _ -> ());
          write fake
            ("#!/bin/sh\n\
              shift\n\
              case \"$1 $2\" in\n\
              'version ') exit 0;;\n\
              'container exists') exit 1;;\n\
              'container inspect') "
            ^ (if mode = "missing" then "exit 125"
               else
                 "if test -f '" ^ stopped ^ "'; then printf '%s' '"
                 ^ (if mode = "verify" then "bad" else fixture "exited")
                 ^ "'; else printf '%s' '"
                 ^ fixture
                     (if mode = "noop" then "exited"
                      else if mode = "paused" then "paused"
                      else "running")
                 ^ "'; fi")
            ^ ";;\n'stop --') test \"$3\" = cid || exit 99; "
            ^ (if mode = "failure" then "exit 125"
               else "touch '" ^ stopped ^ "'")
            ^ ";;\n*) exit 99;;\nesac\n");
          let out, err =
            run ~path:(temp ^ "/fake:/usr/bin:/bin") [ "stop" ] expected
          in
          if expected = 0 then assert (out = output && err = "")
          else (
            assert (out = "" && err <> "");
            assert (contains err "Stop command completed" = (mode = "verify"))))
        [
          ("running", 0, "Stopped example-dev-container\n");
          ("noop", 0, "Already stopped: example-dev-container\n");
          ("owner", 4, "");
          ("missing", 4, "");
          ("paused", 4, "");
          ("failure", 1, "");
          ("verify", 1, "");
        ];
      (* pre_stop runs before the stop and its output streams; a failure keeps
         the container running and returns the hook's status; --no-hooks
         skips it. *)
      write config "[project]\nname='example'\n[hooks]\npre_stop='echo bye'\n";
      ignore (run [ "trust"; "--yes" ] 0);
      (try Unix.unlink log with Unix.Unix_error _ -> ());
      let out, err = run ~path:"/nonexistent" [ "stop"; "-d" ] 0 in
      assert (err = "" && contains out "run the pre_stop hook:\n");
      let out, _ = run ~path:"/nonexistent" [ "stop"; "-d"; "--no-hooks" ] 0 in
      assert (not (contains out "pre_stop"));
      assert (not (Sys.file_exists log));
      let labels =
        Printf.sprintf
          {|"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":%s|}
          (Yojson.Basic.to_string (`String temp))
      in
      let fixture state =
        Printf.sprintf
          {|[{"Id":"cid","Image":"unrelated","State":{"Status":"%s"},"Config":{"Labels":{%s}},"HostConfig":{"UsernsMode":""},"Mounts":[]}]|}
          state labels
      in
      let stopped = temp ^ "/stopped" and removed = temp ^ "/removed" in
      List.iter
        (fun (args, hook_status, expected) ->
          (try Unix.unlink stopped with Unix.Unix_error _ -> ());
          (try Unix.unlink removed with Unix.Unix_error _ -> ());
          (try Unix.unlink log with Unix.Unix_error _ -> ());
          write fake
            ("#!/bin/sh\n\
              shift\n\
              case \"$1 $2\" in\n\
              'version ') exit 0;;\n\
              'container exists'|'image exists') exit 1;;\n\
              'image inspect') exit 125;;\n\
              'container inspect') if test -f '" ^ removed
           ^ "'; then exit 125; elif test -f '" ^ stopped
           ^ "'; then printf '%s' '" ^ fixture "exited"
           ^ "'; else printf '%s' '" ^ fixture "running"
           ^ "'; fi;;\n\
              'exec --') printf 'hook %s\\n' \"$*\" >> \"$DECO_TEST_LOG\"; \
              printf 'hook-output\\n'; exit " ^ string_of_int hook_status
           ^ ";;\n'stop --') printf 'stop\\n' >> \"$DECO_TEST_LOG\"; touch '"
           ^ stopped ^ "';;\n*) exit 99;;\nesac\n");
          let out, err =
            run ~path:(temp ^ "/fake:/usr/bin:/bin") ("stop" :: args) expected
          in
          let calls = if Sys.file_exists log then read log else "" in
          match (args, expected) with
          | [], 0 ->
              assert (err = "hook-output\n");
              assert (out = "Stopped example-dev-container\n");
              assert (
                String.starts_with
                  ~prefix:"hook exec -- cid sh -lc echo bye\nstop\n" calls)
          | [ "--no-hooks" ], 0 ->
              assert (err = "" && contains out "Stopped example-dev-container\n");
              assert (not (contains calls "hook"))
          | _ ->
              assert (out = "");
              assert (
                err
                = "hook-output\n\
                   deco: pre_stop hook failed with exit status 6; the \
                   container was not stopped\n");
              assert (calls = "hook exec -- cid sh -lc echo bye\n"))
        [ ([], 0, 0); ([ "--no-hooks" ], 0, 0); ([], 6, 6) ])
