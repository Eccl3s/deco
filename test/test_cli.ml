let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let write path text =
  Out_channel.with_open_bin path (fun c -> output_string c text)

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-cli-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let last_errors = ref "" in
      let run cwd args expected =
        let out = Filename.concat temp "stdout"
        and err = Filename.concat temp "stderr" in
        let fd path =
          Unix.openfile path [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let stdout = fd out and stderr = fd err in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir cwd;
          Unix.dup2 stdout Unix.stdout;
          Unix.dup2 stderr Unix.stderr;
          Unix.close stdout;
          Unix.close stderr;
          Unix.putenv "PATH" "/nonexistent";
          Unix.execv binary (Array.of_list (binary :: args)));
        Unix.close stdout;
        Unix.close stderr;
        let _, status = Unix.waitpid [] pid in
        assert (status = Unix.WEXITED expected);
        let read p = In_channel.with_open_bin p In_channel.input_all in
        let output, errors = (read out, read err) in
        last_errors := errors;
        if String.contains output '\027' || String.contains errors '\027' then
          failwith
            (Printf.sprintf
               "Unexpected ESC byte: cwd=%S argv=[%s]\nstdout=%S\nstderr=%S" cwd
               (String.concat "; " (List.map (Printf.sprintf "%S") args))
               output errors);
        if expected = 0 then assert (errors = "")
        else assert (output = "" && errors <> "");
        output
      in
      let contains text fragment =
        let rec loop i =
          i + String.length fragment <= String.length text
          && (String.sub text i (String.length fragment) = fragment
             || loop (i + 1))
        in
        loop 0
      in
      let names =
        [
          "alpine";
          "debian";
          "fedora";
          "go";
          "podman";
          "python";
          "rust";
          "tumbleweed";
        ]
      in
      let listing = run temp [ "init"; "--list-templates" ] 0 in
      assert (
        listing
        = "alpine      Alpine development container\n\
           debian      Debian development container\n\
           fedora      Fedora development container\n\
           go          Go development container\n\
           podman      Podman development container\n\
           python      Python uv development container\n\
           rust        Rust development container\n\
           tumbleweed  Tumbleweed development container\n");
      List.iter
        (fun name ->
          let path = Filename.concat temp ("generated-" ^ name) in
          let preview = run temp [ "init"; path; "-t"; name; "-d" ] 0 in
          assert (
            contains preview "Runtime: Podman"
            && contains preview "--- contents ---");
          assert (not (Sys.file_exists path));
          assert (
            run temp [ "init"; path; "--template=" ^ name ] 0
            = Printf.sprintf
                "Initialized Deco configuration using template '%s' in %s.\n"
                name
                (Filename.concat (Unix.realpath temp) ("generated-" ^ name)));
          ignore (run temp [ "validate"; "--project-dir"; path ] 2);
          let file = Filename.concat path ".deco/config.toml" in
          let original = In_channel.with_open_bin file In_channel.input_all in
          ignore (run temp [ "init"; path ] 2);
          assert (In_channel.with_open_bin file In_channel.input_all = original);
          assert (
            run temp [ "init"; path; "-R" ] 0
            = Printf.sprintf
                "Initialized Deco configuration using template 'debian' in %s.\n"
                (Filename.concat (Unix.realpath temp) ("generated-" ^ name))))
        names;
      List.iter
        (fun args -> ignore (run temp ("init" :: args) 2))
        [
          [ "--list-templates"; "." ];
          [ "--list-templates"; "-t"; "debian" ];
          [ "--list-templates"; "-R" ];
          [ "--list-templates"; "-d" ];
          [ "--template"; "unknown" ];
          [ "--template"; "-V" ];
          [ "--templates"; "debian" ];
          [ "--project-dir"; temp ];
        ];
      let default_root = Filename.concat temp "default-init" in
      Unix.mkdir default_root 0o700;
      assert (
        run default_root [ "init" ] 0
        = Printf.sprintf
            "Initialized Deco configuration using template 'debian' in %s.\n"
            (Unix.realpath default_root));
      ignore (run default_root [ "validate" ] 2);
      let spaced = Filename.concat temp "Another Project" in
      ignore (run temp [ "init"; spaced ] 0);
      ignore (run temp [ "validate"; "--project-dir"; spaced ] 2);
      ignore (run temp [ "init"; "--help=plain" ] 0);
      let root = Filename.concat temp "project with spaces" in
      Unix.mkdir root 0o700;
      let deco = Filename.concat root ".deco" in
      Unix.mkdir deco 0o700;
      let build = Filename.concat deco "build" in
      Unix.mkdir build 0o700;
      let file = Filename.concat deco "config.toml" in
      write file "project.name='demo'";
      write (Filename.concat build "Containerfile") "FROM scratch";
      let nested = Filename.concat root "validate" in
      Unix.mkdir nested 0o700;
      let rec snapshot dir =
        Sys.readdir dir |> Array.to_list |> List.sort String.compare
        |> List.concat_map (fun name ->
            let path = Filename.concat dir name in
            if Sys.is_directory path then (path, "directory") :: snapshot path
            else [ (path, In_channel.with_open_bin path In_channel.input_all) ])
      in
      let before = snapshot root in
      let expected = "Configuration valid: " ^ Unix.realpath file ^ "\n" in
      List.iter
        (fun (cwd, args) -> assert (run cwd args 0 = expected))
        [
          (root, [ "validate" ]);
          (nested, [ "validate" ]);
          (temp, [ "--project-dir"; root; "validate" ]);
          (temp, [ "validate"; "--project-dir"; root ]);
          (temp, [ "validate"; "--project-dir=" ^ root ]);
        ];
      assert (snapshot root = before);
      List.iter
        (fun args -> ignore (run temp args 0))
        [
          [];
          [ "-h" ];
          [ "--help" ];
          [ "validate"; "--help" ];
          [ "--help=plain" ];
          [ "validate"; "--help=plain" ];
        ];
      let contains text fragment =
        let rec loop i =
          i + String.length fragment <= String.length text
          && (String.sub text i (String.length fragment) = fragment
             || loop (i + 1))
        in
        loop 0
      in
      let root_help = run temp [ "--help=plain" ] 0 in
      let command_help = run temp [ "validate"; "--help=plain" ] 0 in
      assert (contains command_help "deco validate");
      assert (root_help <> command_help);
      List.iter
        (fun help ->
          List.iter
            (fun code -> assert (not (contains help code)))
            [ "123"; "124"; "125" ];
          assert (contains help "Invalid command usage"))
        [ root_help; command_help ];
      assert (
        run temp [ "--project-dir"; root; "validate"; "-h" ] 0 = command_help);
      assert (run temp [ "-h"; "validate" ] 0 = command_help);
      ignore (run temp [ "validate"; "--"; "-h" ] 2);
      ignore (run temp [ "validate"; "--project-dir"; "-V" ] 2);
      ignore
        (run temp
           [ "validate"; "--project-dir"; root; "--project-dir"; root ]
           2);
      List.iter
        (fun args -> assert (run temp args 0 = Sys.argv.(2) ^ "\n"))
        [ [ "-V" ]; [ "--version" ] ];
      List.iter
        (fun args -> ignore (run temp args 2))
        [
          [ "bad" ];
          [ "validate"; "extra" ];
          [ "validate"; "--project-dir" ];
          [ "validate"; "--project"; "demo" ];
          [ "validate"; "--format=json" ];
          [ "validate"; "-v" ];
          [ "validate"; "--dry-run" ];
          [ "--project-dir"; "validate"; "validate" ];
        ];
      ignore (run root [ "validate"; "--project-dir"; nested ] 2);
      assert (
        !last_errors
        = "deco: Missing configuration: "
          ^ Filename.concat (Unix.realpath nested) ".deco/config.toml"
          ^ "\n");
      List.iter
        (fun text ->
          write file text;
          ignore (run root [ "validate" ] 2))
        [
          "project = ";
          "project.name=1";
          "project.name='demo'\nimage.tag=''";
          "project.name='demo'\nuser.uid=1";
          "project.name='demo'\nbuild.containerfile='../../outside'";
        ];
      write file
        "project.name='demo'\nactions={}\nnetwork={}\nuser.mode='host-user'";
      ignore (run root [ "validate" ] 2);
      let header = "Invalid configuration: " ^ Unix.realpath file ^ "\n\n" in
      assert (
        !last_errors
        = header
          ^ "  actions    Unknown or unsupported key\n\
            \  network    Unknown or unsupported key\n\
            \  user.mode  Unsupported value \"host-user\" (expected one of: \
             \"keep-id\", \"image\")\n");
      write file "project = ";
      ignore (run root [ "validate" ] 2);
      assert (contains !last_errors "  Line 1, column");
      write file "project.name='demo'\nbuild.args.'a.b'=1";
      ignore (run root [ "validate" ] 2);
      assert (contains !last_errors "  build.args.\"a.b\"  Expected a string");
      write file "project.name='demo'\nuser.mode='keep-id'";
      ignore (run root [ "validate" ] 2);
      assert (contains !last_errors "  user.name  Required for keep-id mode");
      assert (String.starts_with ~prefix:header !last_errors);
      write file "project.name='demo'";
      Unix.unlink (Filename.concat build "Containerfile");
      ignore (run root [ "validate" ] 2);
      assert (contains !last_errors "  build.containerfile  ");
      assert (
        String.starts_with
          ~prefix:("Host path check failed: " ^ Unix.realpath file ^ "\n\n")
          !last_errors);
      if Unix.geteuid () <> 0 then (
        Unix.chmod file 0;
        Fun.protect
          ~finally:(fun () -> Unix.chmod file 0o600)
          (fun () ->
            ignore (run root [ "validate" ] 2);
            assert (
              String.starts_with
                ~prefix:("Cannot read configuration: " ^ file ^ "\n\n  ")
                !last_errors))))
