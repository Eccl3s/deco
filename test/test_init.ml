module I = Deco.Init

let ok = function
  | Ok value -> value
  | Error e -> failwith (I.error_to_string e)

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let read path = In_channel.with_open_bin path In_channel.input_all

let write path text =
  Out_channel.with_open_bin path (fun c -> output_string c text)

let () =
  let assets = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-init-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      List.iter
        (fun (template : Deco.Template.t) ->
          let name = template.name in
          assert (
            template.containerfile
            = read (Filename.concat assets (name ^ ".Containerfile")));
          let path = Filename.concat temp name in
          let plan = ok (I.prepare ~path ~template:name ~replace:false) in
          assert (not (Sys.file_exists path));
          ignore (ok (I.apply plan));
          let p =
            match Deco.Project.select ~directory:path with
            | Ok p -> p
            | Error _ -> assert false
          in
          assert (
            template.config_template
            = read (Filename.concat assets (name ^ ".toml")));
          let text = read p.config_path in
          assert (text = Deco.Template.render template ~basename:name);
          let tree = Otoml.Parser.from_string text in
          assert (
            Otoml.find tree Otoml.get_string [ "user"; "name" ]
            = if name = "podman" then "podman" else "dev");
          assert (
            Otoml.find tree Otoml.get_string [ "network"; "mode" ] = "pasta");
          assert (Otoml.find tree Otoml.get_boolean [ "build"; "pull" ]);
          assert (not (String.contains text '{'));
          (match Deco.Config_loader.load p with
          | Ok loaded ->
              assert (List.mem [ "network"; "mode" ] loaded.ignored_paths)
          | Error e -> failwith (Deco.Config_loader.error_to_string e));
          assert (
            read (Filename.concat path ".deco/build/Containerfile")
            = template.containerfile);
          let keep = Filename.concat path ".deco/keep" in
          write keep "preserved";
          assert (
            Result.is_error (I.prepare ~path ~template:name ~replace:false));
          let plan = ok (I.prepare ~path ~template:"debian" ~replace:true) in
          ignore (ok (I.apply plan));
          assert (read keep = "preserved"))
        Deco.Template.all;
      List.iter
        (fun (input, expected) ->
          assert (Deco.Template.project_name input = expected))
        [
          ("Hello World!", "hello-world");
          ("___", "deco-project");
          ("A...B", "a...b");
        ];
      List.iter
        (fun basename ->
          let t = Option.get (Deco.Template.find "debian") in
          let tree =
            Otoml.Parser.from_string (Deco.Template.render t ~basename)
          in
          let project =
            Otoml.find tree Otoml.get_string [ "project"; "name" ]
          in
          let image = Otoml.find tree Otoml.get_string [ "image"; "name" ] in
          let container =
            Otoml.find tree Otoml.get_string [ "container"; "name" ]
          in
          let supported =
            Printf.sprintf "project.name=%S\nimage.name=%S\ncontainer.name=%S"
              project image container
          in
          match Config.Decode.from_string supported with
          | Ok c -> assert (Result.is_ok (Config.Validate.check c))
          | Error _ -> assert false)
        [ String.make 200 'a'; "A...B__C"; "!!!"; "é" ];
      let root = Filename.concat temp "rollback" in
      Unix.mkdir root 0o700;
      let plan = ok (I.prepare ~path:root ~template:"debian" ~replace:false) in
      ignore (ok (I.apply plan));
      let paths = List.map (fun (f : I.file) -> f.path) plan.files in
      List.iter (fun path -> write path "original") paths;
      let plan =
        match
          Init_test_support.prepare ~path:root ~template:"alpine" ~replace:true
        with
        | Ok p -> p
        | Error _ -> assert false
      in
      let result =
        Init_test_support.apply_internal
          ~before_publish:(fun index ->
            if index = 1 then raise (Sys_error "injected failure"))
          plan
      in
      assert (Result.is_error result);
      List.iter (fun path -> assert (read path = "original")) paths;
      let fresh = Filename.concat temp "new/child" in
      let plan =
        match
          Init_test_support.prepare ~path:fresh ~template:"debian"
            ~replace:false
        with
        | Ok p -> p
        | Error _ -> assert false
      in
      assert (
        Result.is_error
          (Init_test_support.apply_internal
             ~before_publish:(fun index ->
               if index = 1 then raise (Sys_error "injected failure"))
             plan));
      assert (not (Sys.file_exists (Filename.concat temp "new")));
      let linkroot = Filename.concat temp "link" in
      Unix.mkdir linkroot 0o700;
      Unix.symlink root (Filename.concat linkroot ".deco");
      assert (
        Result.is_error
          (I.prepare ~path:linkroot ~template:"debian" ~replace:true));
      assert (
        Result.is_error
          (I.prepare ~path:root ~template:"UNKNOWN" ~replace:false)))

let () =
  let temp = Filename.temp_file "deco-init-conflicts-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let deco = Filename.concat temp ".deco" in
      Unix.mkdir deco 0o700;
      let build = Filename.concat deco "build" in
      Unix.mkdir build 0o700;
      let config = Filename.concat deco "config.toml" in
      let containerfile = Filename.concat build "Containerfile" in
      let prepare replace = I.prepare ~path:temp ~template:"debian" ~replace in
      write containerfile "original";
      assert (Result.is_error (prepare false));
      assert (not (Sys.file_exists config));
      Unix.unlink containerfile;
      write config "original";
      assert (Result.is_error (prepare false));
      assert (not (Sys.file_exists containerfile));
      Unix.unlink config;
      Unix.symlink "/nonexistent" config;
      assert (Result.is_error (prepare true));
      Unix.unlink config;
      Unix.rmdir build;
      write build "not-directory";
      assert (Result.is_error (prepare true));
      Unix.unlink build;
      let alias = Filename.concat temp "alias" in
      Unix.symlink temp alias;
      let plan = ok (I.prepare ~path:alias ~template:"debian" ~replace:false) in
      assert (plan.root = Unix.realpath temp);
      write config "file";
      assert (
        Result.is_error
          (I.prepare ~path:config ~template:"debian" ~replace:false)))

let () =
  let base = Option.get (Deco.Template.find "debian") in
  let text =
    "# keep this comment\n\
     project.name='{{project_name}}'\n\
     image.name='{{image_name}}'\n\
     container.name='{{container_name}}'\n\
     unknown.value='$HOME ~ literal'\n"
  in
  let template = { base with config_template = text } in
  assert (
    Deco.Template.render template ~basename:"My Project"
    = "# keep this comment\n\
       project.name='my-project'\n\
       image.name='my-project-dev-image'\n\
       container.name='my-project-dev-container'\n\
       unknown.value='$HOME ~ literal'\n")
