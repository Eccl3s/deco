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

let replace ~pattern ~by text =
  let n = String.length pattern in
  let buffer = Buffer.create (String.length text) in
  let rec loop i =
    if i > String.length text - n then
      Buffer.add_string buffer (String.sub text i (String.length text - i))
    else if String.sub text i n = pattern then (
      Buffer.add_string buffer by;
      loop (i + n))
    else (
      Buffer.add_char buffer text.[i];
      loop (i + 1))
  in
  loop 0;
  Buffer.contents buffer

(* Fake Podman keeping state in marker files next to the call log. MODE selects
   the scenario: ok, nocontainer, noimage, foreign, buildfail, startfail, or
   appear (another running container takes the name right after removal). *)
let script =
  {|#!/bin/sh
shift
L="$DECO_TEST_LOG"
printf '%s\n' "$*" >> "$L"
MODE='@MODE@'
LABELS='"dev.deco.managed":"true","dev.deco.project":"@PROJECT@","dev.deco.project-root":"@ROOT@"'
NEW=00000000000000000000000000000000000000000000000000000000000000ab
if test -f "$L.built"; then IID=iid2; else IID=iid; fi
image_present() { test -f "$L.built" || test "$MODE" != noimage; }
container_present() {
  test -f "$L.created" && return 0
  test ! -f "$L.removed" && test "$MODE" != nocontainer
}
container_json() {
  if test -f "$L.created"; then
    ID=$NEW; IMG=$IID
    if test -f "$L.started"; then S=running; else S=created; fi
  else
    ID=cid; IMG=iid
    if test -f "$L.stopped"; then S=exited; else S=running; fi
  fi
  printf '[{"Id":"%s","Image":"%s","Config":{"Labels":{%s},"User":"","WorkingDir":"/"},"HostConfig":{"Init":true,"UsernsMode":""},"State":{"Status":"%s"},"Mounts":[]}]' "$ID" "$IMG" "$LABELS" "$S"
}
case "$1 $2" in
 'version ') exit 0;;
 'info --format') printf '{}';;
 'image inspect') image_present || exit 125
   printf '[{"Id":"%s","Labels":{%s},"Config":{"User":"","WorkingDir":"/"}}]' "$IID" "$LABELS";;
 'image exists') image_present || exit 1;;
 'container inspect') container_present || exit 125
   if test "$4" = cid && test -f "$L.removed"; then exit 125; fi; container_json;;
 'container exists') container_present || exit 1
   if test "$4" = cid && test -f "$L.removed"; then exit 1; fi;;
 'stop --') touch "$L.stopped";;
 'container rm') touch "$L.removed"
   if test "$MODE" = appear; then touch "$L.created" "$L.started"; fi;;
 'build --file') test "$MODE" = buildfail && exit 1; touch "$L.built";;
 'create --name') touch "$L.created"; printf '%s\n' "$NEW";;
 'start --') test "$MODE" = startfail && exit 125; touch "$L.started";;
 'exec --') case "$MODE:$6" in prestopfail:a|postcreatefail:b) exit 8;; esac
   printf 'hook-%s\n' "$6";;
 *) exit 99;;
esac
|}

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-refresh-cli" "" in
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
      write (temp ^ "/.deco/config.toml") "[project]\nname='example'\n";
      write (temp ^ "/.deco/build/Containerfile") "FROM scratch\n";
      let log = temp ^ "/calls" in
      let fake = temp ^ "/fake/podman" in
      let run ?(path = temp ^ "/fake:/usr/bin:/bin") args expected =
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
        let output = read out and errors = read err in
        if status <> Unix.WEXITED expected then
          failwith
            (Printf.sprintf "deco %s: expected exit %d\nstdout=%s\nstderr=%s"
               (String.concat " " args) expected output errors);
        if String.contains output '\027' || String.contains errors '\027' then
          failwith "Unexpected ESC byte";
        (output, errors)
      in
      let reset () =
        List.iter
          (fun suffix ->
            try Unix.unlink (log ^ suffix) with Unix.Unix_error _ -> ())
          [ ""; ".stopped"; ".removed"; ".built"; ".created"; ".started" ]
      in
      let calls () = if Sys.file_exists log then read log else "" in
      (* Mutating calls in order, as logged by the fake. *)
      let mutations () =
        String.split_on_char '\n' (calls ())
        |> List.filter_map (fun line ->
            match String.split_on_char ' ' line with
            | "stop" :: _ -> Some "stop"
            | "container" :: "rm" :: _ -> Some "rm"
            | "build" :: _ -> Some "build"
            | "create" :: _ -> Some "create"
            | "start" :: _ -> Some "start"
            | "exec" :: rest -> Some ("hook:" ^ List.hd (List.rev rest))
            | _ -> None)
      in
      let install mode =
        reset ();
        write fake
          (script
          |> replace ~pattern:"@MODE@" ~by:mode
          |> replace ~pattern:"@PROJECT@"
               ~by:(if mode = "foreign" then "foreign" else "example")
          |> replace ~pattern:"@ROOT@" ~by:temp);
        Unix.chmod fake 0o700
      in

      (* Trust is required before Podman is used; a dry run only notes it. *)
      let out, err = run [ "refresh" ] 5 in
      assert (out = "" && contains err "deco: configuration for ");
      assert (
        contains err
          " is not trusted\nRun 'deco trust' to review and approve it.\n");
      assert (not (Sys.file_exists log));
      let _, err = run [ "refresh"; "-d" ] 0 in
      assert (
        err
        = "Note: configuration is not trusted; 'deco refresh' would fail with \
           exit code 5.\n");
      assert (not (Sys.file_exists log));
      ignore (run [ "trust"; "--yes" ] 0);

      (* Usage. *)
      ignore (run [ "refresh"; "--help" ] 0);
      List.iter
        (fun args -> ignore (run args 2))
        [
          [ "refresh"; "--volumes" ];
          [ "refresh"; "unexpected" ];
          [ "refresh"; "--project-dir"; "/nonexistent/deco" ];
        ];

      (* Dry runs never invoke Podman. *)
      List.iter
        (fun args ->
          let out, err = run ~path:"/nonexistent" args 0 in
          assert (contains out "Refresh preview" && err = "");
          assert (contains out "podman --remote=false create");
          assert (contains out "podman --remote=false container")
          (* container rm *))
        [
          [ "refresh"; "-d" ]; [ "--project-dir"; temp; "refresh"; "--dry-run" ];
        ];
      let full, _ = run ~path:"/nonexistent" [ "refresh"; "-d" ] 0 in
      let kept, _ =
        run ~path:"/nonexistent" [ "refresh"; "-d"; "--keep-image" ] 0
      in
      assert (contains full "podman --remote=false build");
      assert (not (contains kept "podman --remote=false build"));
      assert (contains kept "Keep the existing image");
      assert (not (Sys.file_exists log));

      (* Podman missing. *)
      ignore (run ~path:"/nonexistent" [ "refresh" ] 3);

      (* Full refresh of a running container. *)
      install "ok";
      let out, err = run [ "refresh" ] 0 in
      assert (err = "");
      (* Lines follow the real order: build, remove, then create and start. *)
      assert (
        out
        = "Rebuilt image example-dev-image:latest\n\
           Stopped and removed container example-dev-container\n\
           Created and started example-dev-container\n");
      assert (mutations () = [ "build"; "stop"; "rm"; "create"; "start" ]);

      (* --keep-image recreates the container without building. *)
      install "ok";
      let out, _ = run [ "refresh"; "--keep-image" ] 0 in
      assert (
        out
        = "Kept image example-dev-image:latest (--keep-image)\n\
           Stopped and removed container example-dev-container\n\
           Created and started example-dev-container\n");
      assert (mutations () = [ "stop"; "rm"; "create"; "start" ]);

      (* No container: continue from the image step. *)
      install "nocontainer";
      let out, _ = run [ "refresh" ] 0 in
      assert (
        out
        = "Rebuilt image example-dev-image:latest\n\
           No existing container: example-dev-container\n\
           Created and started example-dev-container\n");
      assert (mutations () = [ "build"; "create"; "start" ]);

      (* Refusals: exit 4 with nothing changed. *)
      install "noimage";
      let _, err = run [ "refresh"; "--keep-image" ] 4 in
      assert (contains err "Configured image is missing");
      assert (mutations () = []);
      install "foreign";
      ignore (run [ "refresh" ] 4);
      assert (mutations () = []);

      (* A failed build leaves the old container untouched. *)
      install "buildfail";
      let out, err = run [ "refresh" ] 1 in
      assert (out = "");
      assert (not (contains err "Completed command"));
      assert (not (contains err "Refresh is incomplete"));
      (* The build is attempted, and nothing happens after it. *)
      assert (mutations () = [ "build" ]);

      (* A failed start after removal is reported as partial. *)
      install "startfail";
      let out, err = run [ "refresh" ] 1 in
      (* The lines already printed show how far the refresh got. *)
      assert (
        out
        = "Rebuilt image example-dev-image:latest\n\
           Stopped and removed container example-dev-container\n");
      List.iter
        (fun step -> assert (contains err ("Completed command: " ^ step)))
        [
          "image build.";
          "container stop.";
          "container removal.";
          "container creation.";
        ];
      assert (contains err "Refresh is incomplete");
      assert (contains err "run deco refresh again");
      assert (mutations () = [ "build"; "stop"; "rm"; "create"; "start" ]);

      (* A container that takes the name after removal is refused, not
         reported as created. *)
      install "appear";
      let out, err = run [ "refresh" ] 4 in
      assert (not (contains out "Created and started"));
      assert (contains err "appeared during refresh and was not replaced");
      assert (not (contains err "Refresh is incomplete"));
      assert (mutations () = [ "build"; "stop"; "rm" ]);

      (* Hooks: pre_stop before the stop, post_create and post_start after the
         replacement is reported. *)
      write
        (temp ^ "/.deco/config.toml")
        "[project]\n\
         name='example'\n\
         [hooks]\n\
         pre_stop='a'\n\
         post_create='b'\n\
         post_start='c'\n";
      ignore (run [ "trust"; "--yes" ] 0);
      reset ();
      let out, err = run ~path:"/nonexistent" [ "refresh"; "-d" ] 0 in
      assert (err = "" && not (Sys.file_exists log));
      List.iter
        (fun text ->
          if not (contains out text) then failwith (text ^ "\n" ^ out))
        [
          "3. If the container is running, run the pre_stop hook:\n";
          "4. If the container is running, stop it";
          "5. If the container exists, remove it";
          "8. After creating the replacement, run the post_create hook:\n";
          "9. After starting the replacement, run the post_start hook:\n";
          "steps 3 to 5 are skipped";
          "A failed pre_stop hook leaves the existing container running";
          "A failure after step 5 is a partial refresh";
        ];
      install "ok";
      let out, err = run [ "refresh" ] 0 in
      assert (err = "");
      assert (
        out
        = "Rebuilt image example-dev-image:latest\n\
           hook-a\n\
           Stopped and removed container example-dev-container\n\
           Created and started example-dev-container\n\
           hook-b\n\
           hook-c\n");
      assert (
        mutations ()
        = [
            "build";
            "hook:a";
            "stop";
            "rm";
            "create";
            "start";
            "hook:b";
            "hook:c";
          ]);
      (* A failed pre_stop changes no container. *)
      install "prestopfail";
      let out, err = run [ "refresh" ] 8 in
      assert (out = "Rebuilt image example-dev-image:latest\n");
      assert (
        err
        = "deco: pre_stop hook failed with exit status 8\n\
           deco: Completed command: image build.\n\
           deco: The old container example-dev-container was not stopped or \
           removed.\n");
      assert (mutations () = [ "build"; "hook:a" ]);
      (* A failed post_create after the removal is a partial refresh. *)
      install "postcreatefail";
      let out, err = run [ "refresh" ] 8 in
      assert (
        out
        = "Rebuilt image example-dev-image:latest\n\
           hook-a\n\
           Stopped and removed container example-dev-container\n\
           Created and started example-dev-container\n");
      assert (contains err "deco: post_create hook failed with exit status 8\n");
      assert (
        contains err
          "deco: Refresh is incomplete: the old container \
           example-dev-container was removed and the replacement is running, \
           but its post_create hook failed. Fix the problem and run deco \
           refresh again.\n");
      assert (
        mutations ()
        = [ "build"; "hook:a"; "stop"; "rm"; "create"; "start"; "hook:b" ]))
