let write p s = Out_channel.with_open_bin p (fun c -> output_string c s)

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
      assert (not (Sys.file_exists log));
      let _, err = run [ "stop"; "-d" ] 0 in
      assert (
        err
        = "Note: configuration is not trusted; 'deco stop' would fail with \
           exit code 5.\n");
      assert (not (Sys.file_exists log));
      ignore (run [ "trust"; "--yes" ] 0);
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
        ])
