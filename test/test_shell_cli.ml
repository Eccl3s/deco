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
      ignore (run [ "shell"; "--help" ] 0);
      ignore (run [ "shell"; "unexpected" ] 2);
      ignore (run [ "shell"; "--project-dir"; "/nonexistent/deco" ] 2);
      assert (not (Sys.file_exists log));
      List.iter
        (fun args ->
          let out, err = run ~path:"/nonexistent" args 0 in
          assert (
            contains out "Shell preview" && contains out "--tty" && err = ""))
        [
          [ "shell"; "-d" ];
          [ "shell"; "--dry-run"; "--project-dir"; temp ];
          [ "--project-dir"; temp; "shell"; "-d" ];
        ];
      assert (not (Sys.file_exists log)))
