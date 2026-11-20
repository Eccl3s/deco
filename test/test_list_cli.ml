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

(* Fake Podman: DECO_TEST_MODE selects ok, empty, fail, or bad output for the
   container listing; version always succeeds. *)
let script =
  {|#!/bin/sh
shift
printf '%s\n' "$*" >> "$DECO_TEST_LOG"
case "$1" in
  version) exit 0 ;;
  container) ;;
  *) exit 125 ;;
esac
case "$DECO_TEST_MODE" in
  empty) printf '[]' ;;
  fail) printf 'boom\n' >&2; exit 125 ;;
  bad) printf 'nope' ;;
  *) printf '%s' '[
{"Id":"c2","Names":["zeta-dev"],"State":"exited","Image":"localhost/zeta:latest","ImageID":"i2","Labels":{"dev.deco.managed":"true","dev.deco.project":"zeta","dev.deco.project-root":"/src/zeta"}},
{"Id":"c3","Names":["stray"],"State":"running","Image":"","ImageID":"","Labels":{"dev.deco.managed":"true"}},
{"Id":"c1","Names":["alpha-dev"],"State":"running","Image":"localhost/alpha:latest","ImageID":"i1","Labels":{"dev.deco.managed":"true","dev.deco.project":"alpha","dev.deco.project-root":"/src/alpha"}}
]' ;;
esac
|}

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-list-cli" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      Unix.mkdir (temp ^ "/fake") 0o700;
      (* No .deco directory anywhere: list must not need a project. *)
      Unix.mkdir (temp ^ "/work") 0o700;
      let log = temp ^ "/calls" in
      let fake = temp ^ "/fake/podman" in
      write fake script;
      Unix.chmod fake 0o700;
      let run ?(path = temp ^ "/fake") ?(mode = "ok") ?term args expected =
        let out = temp ^ "/out" and err = temp ^ "/err" in
        let fd p =
          Unix.openfile p [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let o = fd out and e = fd err in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir (temp ^ "/work");
          Unix.putenv "PATH" path;
          Unix.putenv "DECO_TEST_LOG" log;
          Unix.putenv "DECO_TEST_MODE" mode;
          Option.iter (Unix.putenv "TERM") term;
          Unix.dup2 o Unix.stdout;
          Unix.dup2 e Unix.stderr;
          Unix.close o;
          Unix.close e;
          Unix.execv binary (Array.of_list (binary :: args)));
        Unix.close o;
        Unix.close e;
        let _, status = Unix.waitpid [] pid in
        let stdout = read out and stderr = read err in
        if status <> Unix.WEXITED expected then
          failwith (String.concat " " args ^ ": " ^ stderr);
        assert (not (String.contains stdout '\027'));
        assert (not (String.contains stderr '\027'));
        (stdout, stderr)
      in
      (* Usage errors never reach Podman. *)
      ignore (run [ "list"; "--help" ] 0);
      ignore (run [ "list"; "--format"; "yaml" ] 2);
      ignore (run [ "list"; "unexpected" ] 2);
      ignore (run [ "list"; "--project-dir"; temp ] 2);
      ignore (run [ "--project-dir"; temp; "list" ] 2);
      assert (not (Sys.file_exists log));
      (* Human output: sorted table, missing values shown as -. *)
      List.iter
        (fun term ->
          let out, err = run ?term [ "list" ] 0 in
          assert (err = "");
          let lines = String.split_on_char '\n' out in
          assert (List.length lines = 8);
          let row n fragments =
            List.iter
              (fun f -> assert (contains (List.nth lines n) f))
              fragments
          in
          row 1 [ "PROJECT"; "CONTAINER"; "STATE"; "IMAGE"; "PROJECT ROOT" ];
          row 3
            [
              "alpha";
              "alpha-dev";
              "running";
              "localhost/alpha:latest";
              "/src/alpha";
            ];
          row 4
            [
              "zeta"; "zeta-dev"; "exited"; "localhost/zeta:latest"; "/src/zeta";
            ];
          row 5 [ "│ -"; "stray"; "running" ];
          assert (not (contains out "c1")))
        [ None; Some "xterm-256color" ];
      assert (
        contains (read log)
          "container ls --all --no-trunc --filter label=dev.deco.managed=true \
           --format json");
      (* JSON output, with the option before or after the command. *)
      List.iter
        (fun args ->
          let out, err = run args 0 in
          assert (err = "");
          assert (String.ends_with ~suffix:"]\n" out);
          match Yojson.Basic.from_string out with
          | `List [ a; z; stray ] ->
              let field name json = Yojson.Basic.Util.member name json in
              assert (field "container_id" a = `String "c1");
              assert (field "project_root" a = `String "/src/alpha");
              assert (field "image_id" a = `String "i1");
              assert (field "state" z = `String "exited");
              assert (field "project" stray = `Null);
              assert (field "image" stray = `Null)
          | _ -> failwith "Unexpected JSON listing")
        [
          [ "list"; "--format"; "json" ];
          [ "list"; "--format=json" ];
          [ "--format"; "json"; "list" ];
          [ "--format=json"; "list" ];
        ];
      (* Empty results succeed. *)
      assert (
        run ~mode:"empty" [ "list" ] 0 = ("No Deco-managed containers.\n", ""));
      assert (run ~mode:"empty" [ "list"; "--format"; "json" ] 0 = ("[]\n", ""));
      (* Failures: unavailable Podman, failed listing, malformed response. *)
      let out, err = run ~path:"/nonexistent" [ "list" ] 3 in
      assert (out = "" && contains err "Podman was not found");
      let out, err = run ~mode:"fail" [ "list"; "--format"; "json" ] 1 in
      assert (out = "" && contains err "container list: exit 125: boom");
      let out, err = run ~mode:"bad" [ "list" ] 1 in
      assert (out = "" && contains err "deco: container list:"))
