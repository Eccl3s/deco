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
      write fake
        "#!/bin/sh\nshift\nprintf 'called\\n' >> \"$DECO_TEST_LOG\"\nexit 125\n";
      Unix.chmod fake 0o700;
      let out, err = run [ "assemble"; "--help" ] 0 in
      assert (contains out "--dry-run" && err = "");
      List.iter
        (fun args ->
          let out, err = run args 0 in
          assert (
            contains out "podman --remote=false build"
            && contains out "'<image-id>'"
            && err = ""))
        [
          [ "assemble"; "--dry-run" ];
          [ "assemble"; "-d" ];
          [ "--project-dir"; temp; "assemble"; "-d" ];
          [ "assemble"; "--project-dir"; temp; "-d" ];
        ];
      assert (not (Sys.file_exists log));
      ignore (run ~path:"/nonexistent" [ "assemble" ] 3);
      ignore (run [ "assemble" ] 3);
      assert (Sys.file_exists log);
      Unix.unlink log;
      write config "[project]\nname=3\n";
      ignore (run [ "assemble" ] 2);
      assert (not (Sys.file_exists log));
      write config "[project]\nname='example'\n";
      let image =
        Printf.sprintf
          {|[{"Id":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":%s},"Config":{}}]|}
          (Yojson.Basic.to_string (`String temp))
      in
      let container ?(owner = "example") () =
        Printf.sprintf
          {|[{"Id":"cid","Image":"iid","Config":{"Labels":{"dev.deco.managed":"true","dev.deco.project":%s,"dev.deco.project-root":%s}},"State":{"Status":"running"},"HostConfig":{"Init":true,"UsernsMode":"host"},"Mounts":[]}]|}
          (Yojson.Basic.to_string (`String owner))
          (Yojson.Basic.to_string (`String temp))
      in
      let script c =
        write fake
          ("#!/bin/sh\n\
            shift\n\
            printf 'called\\n' >> \"$DECO_TEST_LOG\"\n\
            case \"$1 $2\" in\n\
            'image inspect') printf '%s' '" ^ image
         ^ "';;\n'container inspect') printf '%s' '" ^ c ^ "';;\nesac\n")
      in
      script (container ());
      let out, err = run [ "assemble" ] 0 in
      assert (contains out "example-dev-container" && err = "");
      script (container ~owner:"foreign" ());
      ignore (run [ "assemble" ] 4);
      let id = String.make 64 'a' in
      let json = Yojson.Basic.from_string (container ()) in
      let body state =
        match json with
        | `List [ `Assoc fields ] ->
            Yojson.Basic.to_string
              (`List
                 [
                   `Assoc
                     (("Id", `String id)
                     :: ("State", `Assoc [ ("Status", `String state) ])
                     :: List.remove_assoc "Id"
                          (List.remove_assoc "State" fields));
                 ])
        | _ -> assert false
      in
      let creation fail =
        write fake
          ("#!/bin/sh\nshift\ncase \"$1 $2\" in\n'image inspect') printf '%s' '"
         ^ image
         ^ "';;\n\
            'container exists') test -f \"$DECO_TEST_LOG.created\";;\n\
            'container inspect') if test -f \"$DECO_TEST_LOG.started\"; then \
            printf '%s' '" ^ body "running" ^ "'; else printf '%s' '"
         ^ body "created"
         ^ "'; fi;;\n\
            create*) printf x > \"$DECO_TEST_LOG.created\"; printf '%s' '" ^ id
         ^ "';;\nstart*) "
          ^ (if fail then "exit 125"
             else "printf x > \"$DECO_TEST_LOG.started\"")
          ^ ";;\nesac\n")
      in
      creation false;
      let out, err = run [ "assemble" ] 0 in
      assert (contains out "Created and started" && err = "");
      Unix.unlink (log ^ ".created");
      Unix.unlink (log ^ ".started");
      creation true;
      let _, err = run [ "assemble" ] 1 in
      assert (contains err "was created" && contains err "could not be prepared");
      write fake
        "#!/bin/sh\n\
         shift\n\
         case \"$1\" in version|info) exit 0;; *) exit 125;; esac\n";
      ignore (run [ "assemble" ] 1))
