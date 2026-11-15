let () =
  let executable = Unix.realpath Sys.argv.(1) in
  let dir = Filename.temp_file "deco-embed-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  let write path text =
    Out_channel.with_open_bin path (fun c -> output_string c text)
  in
  let cf = Filename.concat dir "sample.Containerfile"
  and toml = Filename.concat dir "sample.toml" in
  let output = Filename.concat dir "output" in
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Unix.unlink (Filename.concat dir name))
        (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () ->
      let run files success =
        let fd =
          Unix.openfile output
            [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ]
            0o600
        in
        let pid =
          Unix.create_process executable
            (Array.of_list (executable :: files))
            Unix.stdin fd fd
        in
        Unix.close fd;
        let _, status = Unix.waitpid [] pid in
        assert (status = Unix.WEXITED 0 = success);
        if not success then
          assert (
            String.length (In_channel.with_open_bin output In_channel.input_all)
            > 0)
      in
      write cf "FROM scratch\n";
      write toml "project.name='{{project_name}}'\n";
      run [ cf; toml ] true;
      run [ cf ] false;
      run [ toml ] false;
      run [ cf; toml; toml ] false;
      write toml "project.name='{{unknown}}'";
      run [ cf; toml ] false;
      write toml "project.name='{{project_name'";
      run [ cf; toml ] false)
