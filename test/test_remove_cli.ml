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
      let out, err = run [ "remove" ] 5 in
      assert (out = "" && contains err "deco: configuration for ");
      assert (
        contains err
          " is not trusted\nRun 'deco trust' to review and approve it.\n");
      assert (not (Sys.file_exists log));
      let _, err = run [ "remove"; "-d" ] 0 in
      assert (
        err
        = "Note: configuration is not trusted; 'deco remove' would fail with \
           exit code 5.\n");
      assert (not (Sys.file_exists log));
      ignore (run [ "trust"; "--yes" ] 0);
      ignore (run [ "remove"; "--help" ] 0);
      List.iter
        (fun args -> ignore (run args 2))
        [
          [ "rm" ];
          [ "remove"; "unexpected" ];
          [ "remove"; "--force" ];
          [ "remove"; "--keep-volumes" ];
          [ "remove"; "--project-dir"; "/nonexistent/deco" ];
        ];
      let help, _ = run [ "--help" ] 0 in
      assert (not (contains help "       rm "));
      assert (not (Sys.file_exists log));
      List.iter
        (fun args ->
          let out, err = run ~path:"/nonexistent" args 0 in
          assert (contains out "Remove preview" && err = ""))
        [
          [ "remove"; "-d" ];
          [ "--project-dir"; temp; "remove"; "--dry-run" ];
          [ "remove"; "--project-dir"; temp; "-d" ];
        ];
      let preview, _ =
        run ~path:"/nonexistent" [ "remove"; "-d"; "--keep-image" ] 0
      in
      assert (not (contains preview "--no-prune"));
      assert (not (Sys.file_exists log));
      assert (
        In_channel.with_open_bin config In_channel.input_all
        = "[project]\nname='example'\n");
      assert (
        In_channel.with_open_bin
          (temp ^ "/.deco/build/Containerfile")
          In_channel.input_all
        = "FROM scratch\n");
      ignore (run [ "remove" ] 3);
      List.iter
        (fun (mode, keep, expected) ->
          List.iter
            (fun suffix ->
              try Unix.unlink (log ^ suffix) with Unix.Unix_error _ -> ())
            [ ""; ".stopped"; ".container"; ".image" ];
          let labels =
            Printf.sprintf
              {|"dev.deco.managed":"true","dev.deco.project":"%s","dev.deco.project-root":%s|}
              (if mode = "owner" then "foreign" else "example")
              (Yojson.Basic.to_string (`String temp))
          in
          let container state =
            Printf.sprintf
              {|[{"Id":"cid","Image":"other-image","State":{"Status":"%s"},"Config":{"Labels":{%s}},"HostConfig":{"UsernsMode":""},"Mounts":[]}]|}
              state labels
          in
          let image =
            Printf.sprintf {|[{"Id":"iid","Labels":{%s},"Config":{}}]|} labels
          in
          let script =
            Printf.sprintf
              {|#!/bin/sh
shift
printf '%%s\n' "$*" >> "$DECO_TEST_LOG"
case "$1 $2" in
 'version ') exit 0;;
 'container inspect') if test -f "$DECO_TEST_LOG.container" || test '%s' = missing; then exit 125; fi
   if test -f "$DECO_TEST_LOG.stopped"; then printf '%%s' '%s'; else printf '%%s' '%s'; fi;;
 'image inspect') if test -f "$DECO_TEST_LOG.image" || test '%s' = missing; then exit 125; fi; printf '%%s' '%s';;
 'container exists'|'image exists') exit 1;;
 'stop --') test "$3" = cid || exit 99; %s;;
 'container rm') test "$3" = -- && test "$4" = cid || exit 99; touch "$DECO_TEST_LOG.container";;
 'container ls') printf '%%s' '%s';;
 'image rm') test "$3" = --no-prune && test "$4" = -- && test "$5" = iid || exit 99; touch "$DECO_TEST_LOG.image"; %s;;
 *) exit 99;;
esac
|}
              mode (container "exited") (container "running") mode image
              (if mode = "failure" then "exit 125"
               else "touch \"$DECO_TEST_LOG.stopped\"")
              (if mode = "dependencies" then
                 {|[{"Id":"a","ImageID":"iid","Names":["dependent"]},{"Id":"z","ImageID":"iid","Names":[]}]|}
               else if mode = "bad-list" then "bad"
               else "[]")
              (if mode = "verification" then "rm \"$DECO_TEST_LOG.image\""
               else ":")
          in
          write fake script;
          let out, err =
            run
              ~path:(temp ^ "/fake:/usr/bin:/bin")
              ([ "remove" ] @ if keep then [ "--keep-image" ] else [])
              expected
          in
          if expected = 0 then (
            assert (err = "");
            assert (
              contains out
                (if mode = "missing" then "Container already absent:"
                 else "Removed container"));
            assert (
              contains out
                (if keep then "Image removal skipped (--keep-image)."
                 else if mode = "missing" then "Image already absent:"
                 else "Removed image")))
          else (
            assert (out = "" && err <> "");
            if mode = "dependencies" then (
              assert (
                contains err "deco:   a (dependent)" && contains err "deco:   z");
              assert (contains err "Completed command: container removal."));
            if mode = "verification" then
              assert (contains err "Completed command: image removal."));
          let calls = In_channel.with_open_bin log In_channel.input_all in
          if keep then
            assert (
              (not (contains calls "image "))
              && not (contains calls "container ls")))
        [
          ("ok", false, 0);
          ("ok", true, 0);
          ("missing", false, 0);
          ("owner", false, 4);
          ("failure", false, 1);
          ("dependencies", false, 4);
          ("bad-list", false, 1);
          ("verification", false, 1);
        ])
