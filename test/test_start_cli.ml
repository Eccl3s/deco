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

(* Fake Podman for one scenario. [project] is the container's project label,
   [label_root] its project-root label (default [root]), [init] its init
   setting, [before] its state until [marker] exists, [after] its state once
   it does, and [start] the shell action for podman start. *)
let script ~root ~marker ?(project = "example") ?label_root ?(init = true)
    ?(missing = false) ?(hook = "exit 96") ~before ~after ~start () =
  let labels ?(root = root) project =
    Printf.sprintf
      {|{"dev.deco.managed":"true","dev.deco.project":"%s","dev.deco.project-root":%s}|}
      project
      (Yojson.Basic.to_string (`String root))
  in
  let container state =
    Printf.sprintf
      {|[{"Id":"cid","Image":"iid","State":{"Status":"%s"},"Config":{"Labels":%s,"WorkingDir":"/"},"HostConfig":{"UsernsMode":"","Init":%b},"Mounts":[]}]|}
      state
      (labels ?root:label_root project)
      init
  in
  let image =
    Printf.sprintf {|[{"Id":"iid","Labels":%s,"Config":{"WorkingDir":"/"}}]|}
      (labels "example")
  in
  String.concat "\n"
    [
      "#!/bin/sh";
      "shift";
      "printf '%s\\n' \"$*\" >> \"$DECO_TEST_LOG\"";
      "case \"$1 $2\" in";
      "'version ') exit 0 ;;";
      "'image inspect') printf '%s' '" ^ image ^ "' ;;";
      "'image exists') exit 0 ;;";
      "'container exists') exit 1 ;;";
      "'container inspect')";
      (if missing then "  exit 125 ;;"
       else
         "  if test -f '" ^ marker ^ "'; then printf '%s' '" ^ container after
         ^ "'; else printf '%s' '" ^ container before ^ "'; fi ;;");
      "'start --') test \"$3\" = cid || exit 98; " ^ start ^ " ;;";
      "'exec --') test \"$3 $4 $5\" = 'cid sh -c' || exit 95; " ^ hook ^ " ;;";
      "*) exit 99 ;;";
      "esac";
      "";
    ]

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-start-cli" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let temp = Unix.realpath temp in
      let mkdir p = Unix.mkdir (temp ^ p) 0o700 in
      mkdir "/.deco";
      mkdir "/.deco/build";
      mkdir "/fake";
      mkdir "/child";
      write (temp ^ "/.deco/config.toml") "[project]\nname='example'\n";
      write (temp ^ "/.deco/build/Containerfile") "FROM scratch\n";
      let log = temp ^ "/calls" and marker = temp ^ "/started" in
      let fake = temp ^ "/fake/podman" in
      let run ?(path = temp ^ "/fake") ?term args expected =
        (try Unix.unlink log with Unix.Unix_error _ -> ());
        let out = temp ^ "/out" and err = temp ^ "/err" in
        let fd p =
          Unix.openfile p [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let o = fd out and e = fd err in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir (temp ^ "/child");
          let inherited =
            Array.to_list (Unix.environment ())
            |> List.filter (fun entry ->
                not
                  (List.exists
                     (fun prefix -> String.starts_with ~prefix entry)
                     [ "PATH="; "TERM="; "DECO_TEST_"; "XDG_STATE_HOME=" ]))
          in
          let env =
            [
              "PATH=" ^ path;
              "XDG_STATE_HOME=" ^ temp ^ "/state";
              "DECO_TEST_LOG=" ^ log;
            ]
            @ Option.to_list (Option.map (fun term -> "TERM=" ^ term) term)
            @ inherited
          in
          Unix.dup2 o Unix.stdout;
          Unix.dup2 e Unix.stderr;
          Unix.close o;
          Unix.close e;
          Unix.execve binary
            (Array.of_list (binary :: args))
            (Array.of_list env));
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
      let calls () = if Sys.file_exists log then read log else "" in
      write fake "#!/bin/sh\nprintf called >> \"$DECO_TEST_LOG\"\nexit 125\n";
      Unix.chmod fake 0o700;
      (* Trust is required before Podman is used; a dry run only notes it. *)
      let out, err = run [ "start" ] 5 in
      assert (out = "" && contains err "deco: configuration for ");
      assert (
        contains err
          " is not trusted\nRun 'deco trust' to review and approve it.\n");
      assert (not (Sys.file_exists log));
      let _, err = run [ "start"; "-d" ] 0 in
      assert (
        err
        = "Note: configuration is not trusted; 'deco start' would fail with \
           exit code 5.\n");
      assert (not (Sys.file_exists log));
      ignore (run [ "trust"; "--yes" ] 0);
      (* Usage errors never reach Podman. *)
      List.iter
        (fun (args, code) ->
          ignore (run args code);
          assert (calls () = ""))
        [
          ([ "start"; "--help" ], 0);
          ([ "start"; "unexpected" ], 2);
          ([ "start"; "--force" ], 2);
          ([ "start"; "--project-dir"; "/nonexistent/deco" ], 2);
        ];
      (* Dry runs need no Podman. *)
      List.iter
        (fun term ->
          List.iter
            (fun args ->
              let out, err = run ~path:"/nonexistent" ?term args 0 in
              assert (contains out "Start preview" && err = "");
              assert (contains out "example-dev-container");
              assert (not (contains out "post_start")))
            [
              [ "start"; "-d" ];
              [ "start"; "--dry-run" ];
              [ "start"; "--project-dir"; temp; "--dry-run" ];
              [ "--project-dir"; temp; "start"; "-d" ];
            ])
        [ None; Some "xterm-256color" ];
      assert (calls () = "");
      let _, err = run ~path:"/nonexistent" [ "start" ] 3 in
      assert (contains err "Podman");
      (* Scenarios against the fake Podman. *)
      let touch = "touch '" ^ marker ^ "'" in
      List.iter
        (fun (name, script, expected, output, fragment) ->
          (try Unix.unlink marker with Unix.Unix_error _ -> ());
          write fake script;
          List.iter
            (fun term ->
              (try Unix.unlink marker with Unix.Unix_error _ -> ());
              let out, err =
                run
                  ~path:(temp ^ "/fake:/usr/bin:/bin")
                  ?term [ "start" ] expected
              in
              let started = contains (calls ()) "start -- cid" in
              if expected = 0 then (
                assert (out = output && err = "");
                assert (started = (output = "Started example-dev-container\n")))
              else (
                assert (out = "");
                if not (contains err fragment) then failwith (name ^ ": " ^ err);
                assert (
                  contains err "Start command completed" = (name = "verify"));
                assert (started = List.mem name [ "failure"; "verify" ])))
            [ None; Some "xterm-256color" ])
        [
          ( "running",
            script ~root:temp ~marker ~before:"running" ~after:"running"
              ~start:"exit 97" (),
            0,
            "Already running: example-dev-container\n",
            "" );
          ( "stopped",
            script ~root:temp ~marker ~before:"exited" ~after:"running"
              ~start:touch (),
            0,
            "Started example-dev-container\n",
            "" );
          ( "missing",
            script ~root:temp ~marker ~missing:true ~before:"exited"
              ~after:"running" ~start:"exit 97" (),
            4,
            "",
            "run deco assemble" );
          ( "owner",
            script ~root:temp ~marker ~project:"foreign" ~before:"exited"
              ~after:"running" ~start:"exit 97" (),
            4,
            "",
            "deco: container example-dev-container belongs to Deco project \
             \"foreign\"\n\
            \  dev.deco.project: expected \"example\", found \"foreign\"\n" );
          (* A moved project; the old root's ESC byte must arrive escaped. *)
          ( "moved",
            script ~root:temp ~marker ~label_root:"/old/\027[31mproject"
              ~before:"exited" ~after:"running" ~start:"exit 97" (),
            4,
            "",
            "If the project was moved from /old/\\x1b[31mproject and that copy \
             no longer exists, remove the old container with:\n\
            \    podman rm example-dev-container\n" );
          ( "incompatible",
            script ~root:temp ~marker ~init:false ~before:"exited"
              ~after:"running" ~start:"exit 97" (),
            4,
            "",
            "init is disabled" );
          ( "paused",
            script ~root:temp ~marker ~before:"paused" ~after:"running"
              ~start:"exit 97" (),
            4,
            "",
            "Unsupported container state" );
          ( "failure",
            script ~root:temp ~marker ~before:"exited" ~after:"running"
              ~start:"printf 'boom\\n' >&2; exit 125" (),
            1,
            "",
            "boom" );
          ( "verify",
            script ~root:temp ~marker ~before:"exited" ~after:"exited"
              ~start:touch (),
            1,
            "",
            "not running after start" );
        ];
      (* post_start runs after Deco starts the container, never for one that is
         already running; a failure keeps the container running and its exit
         status becomes Deco's. *)
      write
        (temp ^ "/.deco/config.toml")
        "[project]\nname='example'\n[hooks]\npost_start='echo ready'\n";
      ignore (run [ "trust"; "--yes" ] 0);
      List.iter
        (fun term ->
          let out, err = run ~path:"/nonexistent" ?term [ "start"; "-d" ] 0 in
          assert (err = "" && calls () = "");
          assert (
            contains out
              "5. If the container was started, run the post_start hook:\n");
          assert (contains out "'echo ready'");
          let scenario ~before ~hook expected =
            (try Unix.unlink marker with Unix.Unix_error _ -> ());
            write fake
              (script ~root:temp ~marker ~before ~after:"running" ~start:touch
                 ~hook ());
            run ~path:(temp ^ "/fake:/usr/bin:/bin") ?term [ "start" ] expected
          in
          let out, err =
            scenario ~before:"exited" ~hook:"echo hook-output; exit 0" 0
          in
          assert (err = "hook-output\n");
          assert (out = "Started example-dev-container\n");
          assert (contains (calls ()) "exec -- cid sh -c echo ready");
          let out, err =
            scenario ~before:"running" ~hook:"echo hook-output; exit 0" 0
          in
          assert (out = "Already running: example-dev-container\n" && err = "");
          assert (not (contains (calls ()) "exec"));
          let out, err = scenario ~before:"exited" ~hook:"exit 7" 7 in
          assert (out = "");
          assert (
            err
            = "deco: post_start hook failed with exit status 7\n\
               deco: Started example-dev-container; it remains running.\n");
          assert (not (contains (calls ()) "stop")))
        [ None; Some "xterm-256color" ])
