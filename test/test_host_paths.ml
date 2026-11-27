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
      (* Env files resolve from the project root, keep configured order, may be
         outside the project, and must be regular files. *)
      let set_env_files values =
        { config with container = { config.container with env_files = values } }
      in
      assert ((ok config).env_files = []);
      let env = join root ".env" in
      write env;
      let elsewhere = join external_dir "app.env" in
      write elsewhere;
      let env_link = join root "env-link" in
      Unix.symlink ".env" env_link;
      assert (
        (ok (set_env_files [ "external_dir/app.env"; ".env"; "~/env-link" ]))
          .env_files = [ elsewhere; env; env ]);
      assert ((ok (set_env_files [ elsewhere ])).env_files = [ elsewhere ]);
      let es =
        bad (set_env_files [ ".env"; "missing.env"; "external_dir"; "~other" ])
      in
      assert (
        List.map (fun (e : Config.Diagnostic.t) -> e.path) es
        = [
            [ "container"; "env_files[1]" ];
            [ "container"; "env_files[2]" ];
            [ "container"; "env_files[3]" ];
          ]);
      (* Protected workspace paths: .deco always, .git when it is a directory,
         each only inside the workspace source; nothing reads Git files. *)
      let workspace = Option.get config.mounts.workspace in
      let set_workspace w = { config with mounts = { workspace = w } } in
      let protection c =
        let p = ok c in
        ( List.map
            (fun (x : H.protected_path) -> (x.source, x.target))
            p.protected,
          p.deco_protection,
          p.git_protection )
      in
      let with_workspace f = set_workspace (Some (f workspace)) in
      assert (
        protection config
        = ([ (deco, "/w/.deco") ], H.Protected, H.Not_applicable));
      assert (
        protection (set_workspace None)
        = ([], H.Not_applicable, H.Not_applicable));
      let git = join root ".git" in
      Unix.mkdir git 0o700;
      assert (
        protection config
        = ([ (deco, "/w/.deco"); (git, "/w/.git") ], H.Protected, H.Protected));
      assert (
        protection (with_workspace (fun w -> { w with protect_git = false }))
        = ([ (deco, "/w/.deco") ], H.Protected, H.Disabled));
      (* Targets join cleanly whatever the configured target. *)
      assert (
        protection (with_workspace (fun w -> { w with target = "/w/" }))
        = ([ (deco, "/w/.deco"); (git, "/w/.git") ], H.Protected, H.Protected));
      assert (
        protection (with_workspace (fun w -> { w with target = "/" }))
        = ([ (deco, "/.deco"); (git, "/.git") ], H.Protected, H.Protected));
      (* A source containing the root maps through the relative path. *)
      let parent = Filename.dirname root and base = Filename.basename root in
      assert (
        protection (with_workspace (fun w -> { w with source = parent }))
        = ( [ (deco, "/w/" ^ base ^ "/.deco"); (git, "/w/" ^ base ^ "/.git") ],
            H.Protected,
            H.Protected ));
      (* A source inside the project sees neither. *)
      assert (
        protection
          (with_workspace (fun w -> { w with source = "external_dir" }))
        = ([], H.Not_applicable, H.Not_applicable));
      assert (
        protection
          (with_workspace (fun w ->
               { w with source = "external_dir"; protect_git = false }))
        = ([], H.Not_applicable, H.Disabled));
      (* A .git file or symbolic link is unprotected, and is never followed. *)
      Unix.rmdir git;
      write git;
      assert (
        protection config = ([ (deco, "/w/.deco") ], H.Protected, H.Unprotected));
      Unix.unlink git;
      Unix.mkdir (join root "real-git") 0o700;
      Unix.symlink "real-git" git;
      assert (
        protection config = ([ (deco, "/w/.deco") ], H.Protected, H.Unprotected));
      Unix.unlink git;
      Unix.symlink "absent" git;
      assert (
        protection config = ([ (deco, "/w/.deco") ], H.Protected, H.Unprotected));
      Unix.unlink git;
      assert (Sys.getcwd () = cwd))
