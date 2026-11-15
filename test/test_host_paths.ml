module H = Deco.Host_paths

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let write path =
  Out_channel.with_open_bin path (fun c -> output_string c "FROM scratch")

let () =
  let cwd = Sys.getcwd () in
  let temp = Filename.temp_file "deco-paths-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let root = Unix.realpath temp in
      let join = Filename.concat in
      let deco = join root ".deco" in
      Unix.mkdir deco 0o700;
      let context = join deco "build" in
      Unix.mkdir context 0o700;
      let file = join context "Containerfile" in
      write file;
      let project : Deco.Project.t =
        { root; config_path = join deco "config.toml" }
      in
      let config =
        match
          Config.Decode.from_string
            "project.name='demo'\nmounts.workspace.target='/w'"
        with
        | Error _ -> assert false
        | Ok c -> (
            match Config.Resolve.apply c with
            | Ok c -> c
            | Error _ -> assert false)
      in
      let ok c =
        match H.resolve ~home_dir:root ~project c with
        | Ok paths -> paths
        | Error _ -> failwith "Unexpected host-path error"
      in
      let bad c =
        match H.resolve ~home_dir:root ~project c with
        | Error es ->
            assert (es <> []);
            es
        | Ok _ -> failwith "Expected host-path errors"
      in
      let set_context value =
        { config with build = { config.build with context = value } }
      in
      let set_file value =
        { config with build = { config.build with containerfile = value } }
      in
      let snapshot = Marshal.to_string config [] in
      let paths = ok config in
      assert (
        paths.build_context = context
        && paths.containerfile = file
        && paths.workspace_source = Some root);
      assert (Marshal.to_string config [] = snapshot);
      assert ((ok (set_context context)).build_context = context);
      assert ((ok (set_file file)).containerfile = file);
      assert ((ok (set_file "~/.deco/build/Containerfile")).containerfile = file);
      assert ((ok (set_context "~/.deco/build")).build_context = context);
      assert (
        (ok { config with mounts = { workspace = None } }).workspace_source
        = None);
      assert (
        Result.is_ok
          (H.resolve ~home_dir:"unused-relative-home" ~project config));
      assert (
        Result.is_error
          (H.resolve ~home_dir:"relative" ~project (set_context "~")));
      List.iter
        (fun path -> ignore (bad (set_context path)))
        [ ""; "  "; "a\000b"; "~someone"; "missing"; file ];
      ignore (bad (set_file context));
      let outside = join root "outside" in
      write outside;
      let sibling = context ^ "-other" in
      Unix.mkdir sibling 0o700;
      let sibling_file = join sibling "Containerfile" in
      write sibling_file;
      List.iter
        (fun path -> ignore (bad (set_file path)))
        [ outside; "../../outside"; sibling_file ];
      let link = join context "link" in
      Unix.symlink outside link;
      ignore (bad (set_file "link"));
      Unix.unlink link;
      Unix.symlink file link;
      assert ((ok (set_file "link")).containerfile = file);
      let alias = join root "context-alias" in
      Unix.symlink context alias;
      assert ((ok (set_context alias)).build_context = context);
      let broken = join root "broken" in
      Unix.symlink "absent" broken;
      ignore (bad (set_context broken));
      let loop = join root "loop" in
      Unix.symlink "loop" loop;
      ignore (bad (set_context loop));
      let external_dir = join root "external_dir" in
      Unix.mkdir external_dir 0o700;
      write (join external_dir "Containerfile");
      let c =
        {
          config with
          build = { config.build with context = "../external_dir" };
        }
      in
      (* Relative paths use the project root, not .deco. *)
      ignore (bad c);
      assert ((ok (set_context external_dir)).build_context = external_dir);
      let literal = join root "$HOME" in
      Unix.mkdir literal 0o700;
      write (join literal "Containerfile");
      assert ((ok (set_context "$HOME")).build_context = literal);
      let workspace = Option.get config.mounts.workspace in
      let c =
        {
          config with
          build = { config.build with context = "missing" };
          mounts = { workspace = Some { workspace with source = "missing" } };
        }
      in
      let es = bad c in
      assert (
        List.map (fun (e : Config.Diagnostic.t) -> e.path) es
        = [ [ "build"; "context" ]; [ "mounts"; "workspace"; "source" ] ]);
      assert (Sys.getcwd () = cwd))
