module P = Deco.Project
module L = Deco.Config_loader

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let write path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

let project = function Ok p -> p | Error e -> failwith (P.error_to_string e)

let loaded p =
  match L.load p with Ok c -> c | Error e -> failwith (L.error_to_string e)

let assert_read_error config_path error =
  match error with
  | L.Read_error { config_path = actual; message } ->
      assert (actual = config_path && message <> "");
      let prefix = config_path ^ ": " in
      assert (not (String.starts_with ~prefix message));
      let rendered = L.error_to_string error in
      assert (rendered = prefix ^ message);
      let tail =
        String.sub rendered (String.length prefix)
          (String.length rendered - String.length prefix)
      in
      let rec contains offset =
        offset + String.length config_path <= String.length tail
        && (String.sub tail offset (String.length config_path) = config_path
           || contains (offset + 1))
      in
      assert (not (contains 0))
  | _ -> failwith "Expected read error"

let () =
  let cwd = Sys.getcwd () in
  let temp = Filename.temp_file "deco-load-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let deco = Filename.concat temp ".deco" in
      Unix.mkdir deco 0o700;
      let build = Filename.concat deco "build" in
      Unix.mkdir build 0o700;
      let containerfile = Filename.concat build "Containerfile" in
      write containerfile "FROM scratch";
      let path = Filename.concat deco "config.toml" in
      let minimal = "project.name='demo'" in
      write path minimal;
      let p = project (P.discover ~start_dir:temp) in
      let c = loaded p in
      assert (
        c.project = p && c.source.build = None && not c.effective.build.pull);
      assert (c.host_paths.build_context = Unix.realpath build);
      assert (c.host_paths.containerfile = Unix.realpath containerfile);
      assert (c.host_paths.workspace_source = None);
      write path (minimal ^ "\nbuild.pull=false");
      let explicit = loaded p in
      assert ((Option.get explicit.source.build).pull = Some false);
      assert (explicit.effective = c.effective);
      write path (minimal ^ "\ncontainer={name='custom',shell='bash'}");
      assert ((loaded p).effective.container.name = "custom");
      write path "project = ";
      (match L.load p with
      | Error
          (L.Decode_errors
             {
               config_path;
               errors = [ Config.Decode.Syntax_error { location = Some _; _ } ];
             }) ->
          assert (config_path = p.config_path)
      | _ -> failwith "Expected syntax error");
      let schema = "project.name=1\ncontainer.shell=false" in
      write path schema;
      (match (L.load p, Config.Decode.from_string schema) with
      | Error (L.Decode_errors { config_path; errors }), Error expected ->
          assert (
            config_path = p.config_path
            && errors = expected
            && List.length errors = 2)
      | _ -> failwith "Expected schema errors");
      let invalid =
        "project.name='" ^ String.make 115 'a' ^ "'\nuser.mode='keep-id'"
      in
      write path invalid;
      (match Config.Decode.from_string invalid with
      | Error _ -> assert false
      | Ok source -> (
          match (L.load p, Config.Resolve.apply source) with
          | Error (L.Validation_errors { config_path; errors }), Error expected
            ->
              assert (config_path = p.config_path && errors = expected);
              let rendered =
                L.error_to_string (L.Validation_errors { config_path; errors })
              in
              assert (
                String.starts_with
                  ~prefix:(p.config_path ^ ": container.name:")
                  rendered);
              assert (
                List.length (String.split_on_char '\n' rendered)
                = List.length errors)
          | _ -> failwith "Expected validation errors"));
      (* Earlier stages must take precedence over invalid filesystem paths. *)
      write path "project.name=1\nbuild.context='missing'";
      (match L.load p with
      | Error (L.Decode_errors _) -> ()
      | _ -> assert false);
      write path (minimal ^ "\nuser.mode='keep-id'\nbuild.context='missing'");
      (match L.load p with
      | Error (L.Validation_errors _) -> ()
      | _ -> assert false);
      let check_paths suffix =
        write path (minimal ^ "\n" ^ suffix);
        let source =
          match Config.Decode.from_string (minimal ^ "\n" ^ suffix) with
          | Ok c -> c
          | Error _ -> assert false
        in
        let effective =
          match Config.Resolve.apply source with
          | Ok c -> c
          | Error _ -> assert false
        in
        match (L.load p, Deco.Host_paths.resolve ~project:p effective) with
        | ( Error (L.Host_path_errors { config_path; errors } as error),
            Error expected ) ->
            assert (config_path = p.config_path && errors = expected);
            assert (
              L.error_to_string error
              = String.concat "\n"
                  (List.map
                     (fun e ->
                       config_path ^ ": " ^ Config.Diagnostic.to_string e)
                     expected))
        | _ -> failwith "Expected matching host-path errors"
      in
      List.iter check_paths
        [
          "build.context='missing'";
          "build.containerfile='missing'";
          "mounts.workspace={target='/w',source='missing'}";
          "build.context='missing'\n\
           mounts.workspace={target='/w',source='missing'}";
        ];
      let outside = Filename.concat temp "outside" in
      write outside "FROM scratch";
      check_paths ("build.containerfile='" ^ outside ^ "'");
      write path (minimal ^ "\nmounts.workspace.target='/w'");
      let workspace_loaded = loaded p in
      assert (workspace_loaded.host_paths.workspace_source = Some p.root);
      assert (
        (Option.get workspace_loaded.effective.mounts.workspace).source = ".");
      write path (minimal ^ "\nbuild.context='~/.deco/build'");
      (match L.load ~home_dir:p.root p with
      | Ok c ->
          assert (
            c.host_paths.build_context = Unix.realpath build
            && c.effective.build.context = "~/.deco/build")
      | _ -> assert false);
      write path
        (minimal
       ^ "\nbuild={context='.deco/build',containerfile='Containerfile'}");
      assert ((loaded p).host_paths.containerfile = Unix.realpath containerfile);
      write path minimal;
      if Unix.geteuid () <> 0 then (
        Unix.chmod path 0;
        Fun.protect
          ~finally:(fun () -> Unix.chmod path 0o600)
          (fun () ->
            match L.load p with
            | Error error -> assert_read_error p.config_path error
            | _ -> failwith "Expected permission failure"));
      Unix.unlink path;
      (match L.load p with
      | Error error -> assert_read_error p.config_path error
      | _ -> failwith "Expected missing file");
      Unix.mkdir path 0o700;
      let native_message =
        try
          ignore (In_channel.with_open_bin path In_channel.input_all);
          assert false
        with Sys_error message -> message
      in
      (match L.load p with
      | Error (L.Read_error { message; _ } as error) ->
          assert_read_error p.config_path error;
          if
            not
              (String.starts_with ~prefix:(p.config_path ^ ": ") native_message)
          then assert (message = native_message)
      | _ -> failwith "Expected directory read error");
      Unix.rmdir path;
      let target = Filename.concat temp "external.toml" in
      write target minimal;
      Unix.symlink target path;
      let c = loaded p in
      assert (c.project = p && c.source.project.name = "demo");
      assert (Sys.getcwd () = cwd))
