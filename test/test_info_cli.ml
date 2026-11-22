(* CLI tests for deco info against a fake Podman that answers only read-only
   queries; any other command fails the run. *)

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

(* One scenario. [image] and [container] are the inspection JSON, or [None]
   when the resource is missing; [inspect_fails] makes the container
   inspection fail while the container still exists. Only shell builtins are
   used, since PATH may hold just the fake. *)
let script ?image ?container ?(inspect_fails = false) () =
  let answer = function
    | Some json -> "printf '%s' '" ^ json ^ "' ;;"
    | None -> "exit 125 ;;"
  in
  String.concat "\n"
    [
      "#!/bin/sh";
      "shift";
      "printf '%s\\n' \"$*\" >> \"$DECO_TEST_LOG\"";
      "case \"$1 $2\" in";
      "'version --format') printf '%s' '{\"Client\":{\"Version\":\"5.7.0\"}}' \
       ;;";
      "'version ') exit 0 ;;";
      "'image inspect') " ^ answer image;
      "'image exists') exit 1 ;;";
      ("'container inspect') "
      ^
      if inspect_fails then "printf 'boom\\n' >&2; exit 125 ;;"
      else answer container);
      ("'container exists') "
      ^ if inspect_fails then "exit 0 ;;" else "exit 1 ;;");
      "*) exit 99 ;;";
      "esac";
      "";
    ]

let labels ~root project =
  Printf.sprintf
    {|{"dev.deco.managed":"true","dev.deco.project":"%s","dev.deco.project-root":%s}|}
    project
    (Yojson.Basic.to_string (`String root))

let image ~root =
  Printf.sprintf
    {|[{"Id":"iid","Created":"2020-01-01T10:00:00.5Z","Labels":%s,"Config":{"WorkingDir":"/"}}]|}
    (labels ~root "example")

let container ~root ?(project = "example") ?(init = true) state =
  Printf.sprintf
    {|[{"Id":"cid","Image":"iid","Created":"2020-01-02T11:30:00+01:00","State":{"Status":"%s"},"Config":{"Labels":%s,"WorkingDir":"/"},"HostConfig":{"UsernsMode":"","Init":%b},"Mounts":[]}]|}
    state (labels ~root project) init

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-info-cli" "" in
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
      mkdir "/other";
      let config = temp ^ "/.deco/config.toml" in
      write config
        "[project]\n\
         name='example'\n\
         [network]\n\
         mode='pasta'\n\
         [actions]\n\
         test='true'\n";
      write (temp ^ "/.deco/build/Containerfile") "FROM scratch\n";
      let log = temp ^ "/calls" in
      let fake = temp ^ "/fake/podman" in
      let run ?(cwd = temp ^ "/child") ?(path = temp ^ "/fake") ?term args
          expected =
        (try Unix.unlink log with Unix.Unix_error _ -> ());
        let out = temp ^ "/out" and err = temp ^ "/err" in
        let fd p =
          Unix.openfile p [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let o = fd out and e = fd err in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir cwd;
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
      let open Yojson.Basic.Util in
      let json text = Yojson.Basic.from_string text in
      let at path j = List.fold_left (fun j key -> member key j) j path in
      write fake "#!/bin/sh\nprintf called >> \"$DECO_TEST_LOG\"\nexit 125\n";
      Unix.chmod fake 0o700;
      (* Usage errors never reach Podman. *)
      List.iter
        (fun (args, code) ->
          ignore (run args code);
          assert (calls () = ""))
        [
          ([ "info"; "--help" ], 0);
          ([ "info"; "--format"; "yaml" ], 2);
          ([ "info"; "unexpected" ], 2);
          ([ "info"; "--dry-run" ], 2);
          ([ "info"; "--project-dir"; "/nonexistent/deco" ], 2);
        ];
      (* Every scenario, with TERM set and unset. *)
      let terms = [ None; Some "xterm-256color" ] in
      let scenario ?image ?container ?inspect_fails () =
        write fake (script ?image ?container ?inspect_fails ())
      in
      let report ?term args =
        let out, err = run ?term args 0 in
        assert (err = "");
        json out
      in
      List.iter
        (fun (name, fake_script, check) ->
          write fake fake_script;
          List.iter
            (fun term ->
              let j = report ?term [ "info"; "--format"; "json" ] in
              (try check j
               with e ->
                 failwith
                   (name ^ ": " ^ Printexc.to_string e ^ "\n"
                   ^ Yojson.Basic.pretty_to_string j));
              (* Podman was only queried. *)
              List.iter
                (fun line ->
                  if
                    line <> ""
                    && not
                         (List.exists
                            (fun prefix -> String.starts_with ~prefix line)
                            [
                              "version";
                              "image inspect";
                              "image exists";
                              "container inspect";
                              "container exists";
                            ])
                  then failwith (name ^ ": unexpected call " ^ line))
                (String.split_on_char '\n' (calls ())))
            terms)
        [
          ( "running",
            script ~image:(image ~root:temp)
              ~container:(container ~root:temp "running")
              (),
            fun j ->
              assert (at [ "project"; "name" ] j = `String "example");
              assert (at [ "project"; "root" ] j = `String temp);
              assert (at [ "project"; "config" ] j = `String config);
              assert (at [ "podman"; "available" ] j = `Bool true);
              assert (at [ "podman"; "version" ] j = `String "5.7.0");
              assert (at [ "image"; "id" ] j = `String "iid");
              assert (
                at [ "image"; "created" ] j = `String "2020-01-01T10:00:00Z");
              assert (at [ "image"; "owned" ] j = `Bool true);
              assert (at [ "container"; "id" ] j = `String "cid");
              assert (at [ "container"; "state" ] j = `String "running");
              assert (
                at [ "container"; "created" ] j = `String "2020-01-02T10:30:00Z");
              assert (at [ "container"; "compatible" ] j = `Bool true);
              assert (at [ "runtime"; "workdir" ] j = `String "/");
              assert (at [ "actions" ] j = `List [ `String "test" ]) );
          ( "stopped",
            script ~image:(image ~root:temp)
              ~container:(container ~root:temp "exited")
              (),
            fun j ->
              assert (at [ "container"; "state" ] j = `String "stopped");
              assert (at [ "container"; "podman_state" ] j = `String "exited")
          );
          ( "missing",
            script (),
            fun j ->
              assert (at [ "image"; "exists" ] j = `Bool false);
              assert (at [ "image"; "id" ] j = `Null);
              assert (at [ "container"; "exists" ] j = `Bool false);
              assert (at [ "container"; "state" ] j = `Null);
              assert (at [ "container"; "compatible" ] j = `Null) );
          ( "foreign",
            script ~image:(image ~root:temp)
              ~container:(container ~root:temp ~project:"other" "running")
              (),
            fun j ->
              assert (at [ "container"; "owned" ] j = `Bool false);
              assert (at [ "container"; "compatible" ] j = `Null) );
          ( "incompatible",
            script ~image:(image ~root:temp)
              ~container:(container ~root:temp ~init:false "exited")
              (),
            fun j ->
              assert (at [ "container"; "compatible" ] j = `Bool false);
              assert (
                at [ "container"; "incompatibilities" ] j
                = `List [ `String "Container init is disabled" ]) );
        ];
      (* Human output, the option on either side of the command, and
         --project-dir from an unrelated directory. *)
      scenario ~image:(image ~root:temp)
        ~container:(container ~root:temp ~init:false "exited")
        ();
      List.iter
        (fun term ->
          let out, err = run ?term [ "info" ] 0 in
          assert (err = "");
          List.iter
            (fun fragment ->
              if not (contains out fragment) then
                failwith (fragment ^ "\n" ^ out))
            [
              "Project\n  Name:        example\n";
              "  Root:        " ^ temp ^ "\n";
              "  Created:     2020-01-01 10:00 UTC (";
              " days ago)\n";
              "  State:       stopped (exited)\n";
              "  Compatible:  no\n    - Container init is disabled\n";
              "Actions\n  test\n";
              "Ignored planned settings (not applied yet):\n  network.mode\n";
            ];
          let expected = run ?term [ "info"; "--format"; "json" ] 0 in
          List.iter
            (fun args ->
              assert (run ~cwd:(temp ^ "/other") ?term args 0 = expected))
            [
              [ "--format"; "json"; "info"; "--project-dir"; temp ];
              [ "--format=json"; "--project-dir"; temp; "info" ];
              [ "info"; "--project-dir=" ^ temp; "--format=json" ];
            ])
        terms;
      (* Podman unavailable: the full report, the reason, and exit 3. *)
      List.iter
        (fun term ->
          let out, err =
            run ~path:"/nonexistent" ?term [ "info"; "--format"; "json" ] 3
          in
          let j = json out in
          assert (contains err "Podman was not found on PATH");
          assert (at [ "podman"; "available" ] j = `Bool false);
          assert (at [ "podman"; "version" ] j = `Null);
          assert (at [ "project"; "name" ] j = `String "example");
          assert (at [ "image"; "exists" ] j = `Null);
          assert (at [ "container"; "exists" ] j = `Null);
          let out, _ = run ~path:"/nonexistent" ?term [ "info" ] 3 in
          assert (contains out "  Available:   no\n"))
        terms;
      (* Trust is reported without being required. *)
      scenario ~image:(image ~root:temp)
        ~container:(container ~root:temp "running")
        ();
      let trust () = at [ "trust" ] (report [ "info"; "--format"; "json" ]) in
      let t = trust () in
      assert (at [ "state" ] t = `String "untrusted");
      assert (
        String.starts_with ~prefix:"blake2b-256:"
          (to_string (at [ "digest" ] t)));
      assert (at [ "trusted_at" ] t = `Null);
      assert (at [ "changed" ] t = `List []);
      ignore (run [ "trust"; "--yes" ] 0);
      let t = trust () in
      assert (at [ "state" ] t = `String "trusted");
      assert (at [ "trusted_at" ] t <> `Null);
      assert (at [ "changed" ] t = `List []);
      let containerfile = temp ^ "/.deco/build/Containerfile" in
      write containerfile "FROM alpine\n";
      let t = trust () in
      assert (at [ "state" ] t = `String "changed");
      assert (at [ "trusted_at" ] t <> `Null);
      assert (
        at [ "changed" ] t
        = `List
            [
              `Assoc
                [
                  ("path", `String "build/Containerfile");
                  ("change", `String "modified");
                ];
            ]);
      List.iter
        (fun term ->
          let out, err = run ?term [ "info" ] 0 in
          assert (err = "");
          let section =
            "  Config:      " ^ config
            ^ "\n\nTrust\n  State:       changed\n  Digest:      blake2b-256:"
          in
          if not (contains out section) then failwith out;
          assert (contains out "    - modified build/Containerfile\n\nPodman\n"))
        terms;
      (* An unusable record is reported once on stderr; info still succeeds. *)
      let records = temp ^ "/state/deco/trust" in
      Array.iter
        (fun name -> write (Filename.concat records name) "corrupt")
        (Sys.readdir records);
      let out, err = run [ "info"; "--format"; "json" ] 0 in
      assert (at [ "trust"; "state" ] (json out) = `String "untrusted");
      assert (String.starts_with ~prefix:"deco: Ignoring trust record " err);
      (* A digest failure still prints the report, with trust unknown, and
         exits 2. *)
      let pipe = temp ^ "/.deco/pipe" in
      Unix.mkfifo pipe 0o600;
      List.iter
        (fun term ->
          let out, err = run ?term [ "info"; "--format"; "json" ] 2 in
          assert (at [ "trust" ] (json out) = `Null);
          assert (at [ "container"; "state" ] (json out) = `String "running");
          assert (contains err "unsupported file type");
          let out, _ = run ?term [ "info" ] 2 in
          assert (contains out "Trust\n  State:       -\n"))
        terms;
      Unix.unlink pipe;
      write containerfile "FROM scratch\n";
      (* Any other Podman failure: no report, exit 1. *)
      scenario ~image:(image ~root:temp) ~inspect_fails:true ();
      let out, err = run [ "info" ] 1 in
      assert (out = "" && contains err "boom");
      (* Invalid configuration: no report, exit 2, no Podman. *)
      write config "[project]\nname='example'\nbogus=1\n";
      let out, err = run [ "info"; "--format"; "json" ] 2 in
      assert (out = "" && contains err config);
      assert (calls () = ""))
