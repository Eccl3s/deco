(* CLI tests for selecting a project by name with -p/--project. A fake Podman
   answers the availability probe and the managed-container listing and fails
   every other command, so a passing run proves that only read-only lookups
   happened. *)

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

(* DECO_TEST_LISTING names a one-line file printed for the listing;
   DECO_TEST_FAIL makes the listing fail. Only shell builtins are used, since
   PATH holds just the fake. *)
let script =
  {|#!/bin/sh
shift
printf '%s\n' "$*" >> "$DECO_TEST_LOG"
case "$1 $2" in
  'version ') exit 0 ;;
  'container ls')
    if test -n "$DECO_TEST_FAIL"; then printf 'boom\n' >&2; exit 125; fi
    IFS= read -r listing < "$DECO_TEST_LISTING"
    printf '%s' "$listing" ;;
  *) exit 99 ;;
esac
|}

let container ~project ~root id =
  Printf.sprintf
    {|{"Id":"%s","Names":["%s-dev-container"],"State":"exited","Image":"localhost/i:latest","ImageID":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":%s,"dev.deco.project-root":%s}}|}
    id project
    (Yojson.Basic.to_string (`String project))
    (Yojson.Basic.to_string (`String root))

let project root name =
  Unix.mkdir root 0o700;
  Unix.mkdir (root ^ "/.deco") 0o700;
  Unix.mkdir (root ^ "/.deco/build") 0o700;
  write (root ^ "/.deco/config.toml") ("[project]\nname='" ^ name ^ "'\n");
  write (root ^ "/.deco/build/Containerfile") "FROM scratch\n"

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-project-cli" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let temp = Unix.realpath temp in
      Unix.mkdir (temp ^ "/fake") 0o700;
      (* An unrelated working directory: discovery would find nothing. *)
      Unix.mkdir (temp ^ "/work") 0o700;
      let zeta = temp ^ "/zeta" in
      project zeta "zeta";
      let log = temp ^ "/calls" and listing = temp ^ "/listing" in
      let fake = temp ^ "/fake/podman" in
      write fake script;
      Unix.chmod fake 0o700;
      let set_listing containers =
        write listing ("[" ^ String.concat "," containers ^ "]")
      in
      let calls () = if Sys.file_exists log then read log else "" in
      let run ?(path = temp ^ "/fake") ?(fail = false) ?term args expected =
        (try Unix.unlink log with Unix.Unix_error _ -> ());
        let out = temp ^ "/out" and err = temp ^ "/err" in
        let fd p =
          Unix.openfile p [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let o = fd out and e = fd err in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir (temp ^ "/work");
          let inherited =
            Array.to_list (Unix.environment ())
            |> List.filter (fun entry ->
                not
                  (List.exists
                     (fun prefix -> String.starts_with ~prefix entry)
                     [ "PATH="; "TERM="; "DECO_TEST_" ]))
          in
          let env =
            [
              "PATH=" ^ path;
              "DECO_TEST_LOG=" ^ log;
              "DECO_TEST_LISTING=" ^ listing;
              ("DECO_TEST_FAIL=" ^ if fail then "1" else "");
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
      let lookup_only () =
        assert (
          calls ()
          = "version\n\
             container ls --all --no-trunc --filter \
             label=dev.deco.managed=true --format json\n")
      in
      set_listing [ container ~project:"zeta" ~root:zeta "c1" ];
      (* Every project command accepts the option before or after the command
         and, with --dry-run, performs only the read-only lookup. *)
      let config = zeta ^ "/.deco/config.toml" in
      List.iter
        (fun term ->
          List.iter
            (fun (command, rest, expected_output) ->
              List.iter
                (fun args ->
                  let stdout, stderr = run ?term args 0 in
                  assert (List.for_all (contains stdout) expected_output);
                  assert (stderr = "");
                  lookup_only ())
                [
                  command :: "-p" :: "zeta" :: rest;
                  "-p" :: "zeta" :: command :: rest;
                  command :: "--project" :: "zeta" :: rest;
                  "--project=zeta" :: command :: rest;
                ])
            [
              ("validate", [], [ "Configuration valid: " ^ config ]);
              ("assemble", [ "--dry-run" ], [ "Assemble preview"; zeta ]);
              ("refresh", [ "--dry-run" ], [ "Refresh preview"; zeta ]);
              ("remove", [ "--dry-run" ], [ "Remove preview" ]);
              ("stop", [ "--dry-run" ], [ "Stop preview" ]);
              ("shell", [ "--dry-run" ], [ "Shell preview" ]);
              ("exec", [ "--dry-run"; "--"; "true" ], [ "Exec preview" ]);
            ])
        [ None; Some "xterm-256color" ];
      (* The option is not accepted with --project-dir, empty, or by init. *)
      List.iter
        (fun args ->
          let _, stderr = run args 2 in
          assert (stderr <> "");
          assert (calls () = ""))
        [
          [ "stop"; "-p"; "zeta"; "--project-dir"; zeta; "--dry-run" ];
          [ "--project-dir"; zeta; "-p"; "zeta"; "validate" ];
          [ "validate"; "--project-dir=" ^ zeta; "--project=zeta" ];
          [ "validate"; "-p"; "" ];
          [ "init"; "-p"; "zeta" ];
          [ "-p"; "zeta"; "init" ];
        ];
      let _, stderr =
        run [ "validate"; "-p"; "zeta"; "--project-dir"; zeta ] 2
      in
      assert (contains stderr "mutually exclusive");
      (* No match. *)
      let _, stderr = run [ "stop"; "-p"; "nope"; "--dry-run" ] 2 in
      assert (contains stderr "No assembled project named \"nope\"");
      lookup_only ();
      (* Duplicates of one root are a single match; distinct roots are
         ambiguous. *)
      let second = temp ^ "/second" in
      project second "zeta";
      set_listing
        [
          container ~project:"zeta" ~root:zeta "c1";
          container ~project:"zeta" ~root:zeta "c2";
        ];
      ignore (run [ "validate"; "-p"; "zeta" ] 0);
      set_listing
        [
          container ~project:"zeta" ~root:zeta "c1";
          container ~project:"zeta" ~root:second "c2";
        ];
      let _, stderr = run [ "stop"; "-p"; "zeta"; "--dry-run" ] 2 in
      assert (contains stderr "--project-dir");
      assert (contains stderr zeta && contains stderr second);
      (* A deleted root, and a root naming another project. *)
      set_listing [ container ~project:"gone" ~root:(temp ^ "/gone") "c3" ];
      let _, stderr = run [ "stop"; "-p"; "gone"; "--dry-run" ] 2 in
      assert (contains stderr (temp ^ "/gone"));
      set_listing [ container ~project:"beta" ~root:zeta "c4" ];
      let _, stderr = run [ "stop"; "-p"; "beta"; "--dry-run" ] 2 in
      assert (contains stderr "names project \"zeta\"");
      (* An invalid configuration at the matching root is reported with its
         path before any further Podman operation. *)
      write (second ^ "/.deco/config.toml") "[project]\nname='zeta'\nbogus=1\n";
      set_listing [ container ~project:"zeta" ~root:second "c2" ];
      let _, stderr = run [ "stop"; "-p"; "zeta" ] 2 in
      assert (contains stderr (second ^ "/.deco/config.toml"));
      lookup_only ();
      (* Podman unavailable is 3; a failing listing is a runtime failure. *)
      let _, stderr = run ~path:"/nonexistent" [ "stop"; "-p"; "zeta" ] 3 in
      assert (contains stderr "Podman");
      let _, stderr = run ~fail:true [ "stop"; "-p"; "zeta"; "--dry-run" ] 1 in
      assert (contains stderr "boom"))
