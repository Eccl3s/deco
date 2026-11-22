(* CLI tests for deco actions. Listing needs no Podman and no trust; -p NAME
   uses only the read-only project lookup. *)

let write p s = Out_channel.with_open_bin p (fun c -> output_string c s)
let read p = In_channel.with_open_bin p In_channel.input_all

let contains s fragment =
  let rec loop i =
    i + String.length fragment <= String.length s
    && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let rec cleanup p =
  if (Unix.lstat p).st_kind = Unix.S_DIR then (
    Array.iter (fun n -> cleanup (Filename.concat p n)) (Sys.readdir p);
    Unix.rmdir p)
  else Unix.unlink p

(* Answers the availability probe and the managed-container listing only. *)
let script listing =
  {|#!/bin/sh
shift
printf '%s\n' "$*" >> "$DECO_TEST_LOG"
case "$1 $2" in
  'version ') exit 0 ;;
  'container ls') printf '%s' '|}
  ^ listing ^ {|' ;;
  *) exit 99 ;;
esac
|}

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-actions-cli" "" in
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
      let run ?(cwd = root) ?(path = "/nonexistent") ?term args expected =
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
      List.iter
        (fun term ->
          (* No actions: success with an empty list. The configuration is not
             trusted, which listing does not require, and Podman is not on
             PATH. *)
          write config "[project]\nname='example'\n";
          let out, err = run ?term [ "actions" ] 0 in
          assert (out = "No actions configured.\n" && err = "");
          let out, _ = run ?term [ "actions"; "--format"; "json" ] 0 in
          assert (out = "[]\n");
          (* Sorted by name, in both formats, with hostile text escaped in human
             output. *)
          write config
            "[project]\n\
             name='example'\n\
             [actions]\n\
             test = 'make test'\n\
             build = \"make\\u001b[31m\"\n\
             Lint = 'make lint'\n";
          let out, err = run ?term [ "actions" ] 0 in
          assert (err = "");
          assert (
            out
            = "┌───────┬──────────────┐\n\
               │ NAME  │ COMMAND      │\n\
               ├───────┼──────────────┤\n\
               │ Lint  │ make lint    │\n\
               │ build │ make\\x1b[31m │\n\
               │ test  │ make test    │\n\
               └───────┴──────────────┘\n");
          List.iter
            (fun args ->
              let out, err = run ?term args 0 in
              assert (err = "");
              assert (
                Yojson.Basic.from_string out
                = `List
                    [
                      `Assoc
                        [
                          ("name", `String "Lint");
                          ("command", `String "make lint");
                        ];
                      `Assoc
                        [
                          ("name", `String "build");
                          ("command", `String "make\027[31m");
                        ];
                      `Assoc
                        [
                          ("name", `String "test");
                          ("command", `String "make test");
                        ];
                    ]))
            [
              [ "actions"; "--format"; "json" ];
              [ "--format=json"; "actions" ];
              [ "actions"; "--project-dir"; root; "--format"; "json" ];
            ];
          assert (not (Sys.file_exists log));
          (* -p NAME locates the project with the read-only listing alone. *)
          let fake = temp ^ "/fake/podman" in
          write fake
            (script
               (Printf.sprintf
                  {|[{"Id":"cid","Names":["example-dev-container"],"State":"exited","Image":"localhost/i:latest","ImageID":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":%s}}]|}
                  (Yojson.Basic.to_string (`String root))));
          Unix.chmod fake 0o700;
          List.iter
            (fun args ->
              let out, err =
                run ~cwd:(temp ^ "/work") ~path:(temp ^ "/fake") ?term args 0
              in
              assert (err = "");
              assert (contains out "│ Lint  │ make lint    │\n");
              assert (
                read log
                = "version\n\
                   container ls --all --no-trunc --filter \
                   label=dev.deco.managed=true --format json\n"))
            [ [ "actions"; "-p"; "example" ]; [ "-p"; "example"; "actions" ] ];
          (* Invalid configuration and usage errors. *)
          write config "[project]\nname='example'\n[actions]\n'1x'='y'\n";
          let _, err = run ?term [ "actions" ] 2 in
          assert (err <> "");
          ignore (run ?term [ "actions"; "--format"; "yaml" ] 2);
          ignore (run ?term [ "actions"; "unexpected" ] 2))
        [ None; Some "xterm-256color" ])
