(* CLI tests for deco run against a fake Podman. *)

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

(* ROOT is replaced with the JSON-quoted project root. Hooks ([exec --]) are
   logged; the action ([exec --interactive]) runs on the host. *)
let script =
  {|#!/bin/sh
shift
case "$1 $2" in
  'version ') exit 0;;
  'info --format') printf '{}';;
  'image exists') exit 0;;
  'container exists') [ -z "$DECO_TEST_MISSING" ];;
  'container ls') printf '%s' '[{"Id":"cid","Names":["example-dev-container"],"State":"running","Image":"localhost/i:latest","ImageID":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":ROOT}}]';;
  'image inspect') printf '%s' '[{"Id":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":ROOT},"Config":{"WorkingDir":"/"}}]';;
  'container inspect') [ -z "$DECO_TEST_MISSING" ] || exit 125; state=running; if [ -n "$DECO_TEST_STOPPED" ] && [ ! -f "$DECO_TEST_LOG.started" ]; then state=exited; fi; printf '%s' '[{"Id":"cid","Image":"iid","State":{"Status":"'"$state"'"},"Config":{"Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":ROOT},"WorkingDir":"/"},"HostConfig":{"UsernsMode":"","Init":true},"Mounts":[]}]';;
  'start --') [ "$3" = cid ] || exit 93; : > "$DECO_TEST_LOG.started";;
  'exec --') printf '%s\n' "$*" >> "$DECO_TEST_LOG"; printf 'hook-output\n'; exit 0;;
  'exec --interactive') shift; shift; [ "$1" = -- ] || exit 90; shift; [ "$1" = cid ] || exit 91; shift; exec "$@";;
  *) exit 92;;
esac
|}

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-run-cli" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let temp = Unix.realpath temp in
      let root = temp ^ "/project" in
      List.iter
        (fun p -> Unix.mkdir p 0o700)
        [
          temp ^ "/fake";
          temp ^ "/work";
          root;
          root ^ "/.deco";
          root ^ "/.deco/build";
        ];
      write (root ^ "/.deco/build/Containerfile") "FROM scratch\n";
      let config = root ^ "/.deco/config.toml" in
      let log = temp ^ "/calls" in
      let fake = temp ^ "/fake/podman" in
      write fake
        (Str.global_substitute (Str.regexp_string "ROOT")
           (fun _ -> Yojson.Basic.to_string (`String root))
           script);
      Unix.chmod fake 0o700;
      let run ?(cwd = root) ?(path = temp ^ "/fake:/usr/bin:/bin") ?term
          ?(env = []) args expected =
        (try Unix.unlink log with Unix.Unix_error _ -> ());
        (try Unix.unlink (log ^ ".started") with Unix.Unix_error _ -> ());
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
            @ List.map (fun (key, value) -> key ^ "=" ^ value) env
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
      let hook_calls () =
        if Sys.file_exists log then
          List.length
            (List.filter
               (fun line -> String.starts_with ~prefix:"exec -- cid" line)
               (String.split_on_char '\n' (read log)))
        else 0
      in
      List.iter
        (fun term ->
          let state = temp ^ "/state" in
          if Sys.file_exists state then cleanup state;
          write config
            "[project]\n\
             name='example'\n\
             [hooks]\n\
             post_start='echo ready'\n\
             [actions]\n\
             ok = 'printf output; printf error >&2'\n\
             fail = 'exit 3'\n\
             hostile = \"printf '\\u001b[31m'\"\n";
          (* Trust is required; a dry run only notes it. *)
          let out, err = run ?term [ "run"; "ok" ] 5 in
          assert (out = "" && contains err " is not trusted\n");
          assert (not (Sys.file_exists log));
          let out, err =
            run ~path:"/nonexistent" ?term [ "run"; "-d"; "ok" ] 0
          in
          assert (contains out "Run preview");
          assert (
            err
            = "Note: configuration is not trusted; 'deco run' would fail with \
               exit code 5.\n");
          ignore (run ?term [ "trust"; "--yes" ] 0);
          (* The dry run needs no Podman, lists the post_start hook and escapes
             the command. *)
          let out, err =
            run ~path:"/nonexistent" ?term [ "run"; "--dry-run"; "hostile" ] 0
          in
          assert (err = "");
          assert (
            contains out
              "4. If the container was started, run the post_start hook:\n");
          assert (contains out "5. Run action hostile:\n");
          assert (contains out "\\x1b[31m");
          (* Output streams and the exit status pass through. *)
          let out, err = run ?term [ "run"; "ok" ] 0 in
          assert (out = "output" && err = "error");
          assert (hook_calls () = 0);
          ignore (run ?term [ "run"; "fail" ] 3);
          (* A stopped container is started and post_start runs first. *)
          let out, err =
            run ?term ~env:[ ("DECO_TEST_STOPPED", "1") ] [ "run"; "ok" ] 0
          in
          assert (out = "output" && err = "hook-output\nerror");
          assert (hook_calls () = 1);
          (* A missing container is a state conflict. *)
          let out, err =
            run ?term ~env:[ ("DECO_TEST_MISSING", "1") ] [ "run"; "ok" ] 4
          in
          assert (out = "" && contains err "Container is missing");
          (* Unknown actions are usage errors that point at deco actions, in
             both modes; names are case-sensitive. *)
          List.iter
            (fun args ->
              let out, err = run ?term args 2 in
              assert (out = "");
              assert (
                contains err
                  "deco: Unknown action \"OK\"; run 'deco actions' to list the \
                   configured actions.\n"))
            [ [ "run"; "OK" ]; [ "run"; "-d"; "OK" ] ];
          let _, err = run ?term [ "run"; "\027[31m" ] 2 in
          assert (contains err "\\x1b[31m");
          (* A missing ACTION and extra arguments are usage errors. *)
          ignore (run ?term [ "run" ] 2);
          ignore (run ?term [ "run"; "ok"; "extra" ] 2);
          (* -p NAME selects the project from anywhere, before or after the
             command. *)
          List.iter
            (fun args ->
              let out, _ = run ~cwd:(temp ^ "/work") ?term args 0 in
              assert (out = "output"))
            [
              [ "run"; "ok"; "-p"; "example" ]; [ "-p"; "example"; "run"; "ok" ];
            ])
        [ None; Some "xterm-256color" ])
