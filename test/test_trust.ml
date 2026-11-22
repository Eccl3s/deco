module T = Deco.Trust
module D = Deco.Trust_digest
module S = Deco.Trust_store

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let write path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

let contains s fragment =
  let rec loop i =
    i + String.length fragment <= String.length s
    && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let () =
  let temp = Filename.temp_file "deco-trust-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let root = Filename.concat (Unix.realpath temp) "project" in
      Unix.mkdir root 0o700;
      Unix.mkdir (Filename.concat root ".deco") 0o700;
      Unix.mkdir (Filename.concat root ".deco/build") 0o700;
      write (Filename.concat root ".deco/config.toml") "project.name='demo'\n";
      let containerfile = Filename.concat root ".deco/build/Containerfile" in
      write containerfile "FROM scratch\n";
      let store_dir = Filename.concat temp "store" in
      let check () =
        let loaded =
          match Deco.Project.select ~directory:root with
          | Error e -> failwith (Deco.Project.error_to_string e)
          | Ok project -> (
              match Deco.Config_loader.load project with
              | Ok loaded -> loaded
              | Error e -> failwith (Deco.Config_loader.error_to_string e))
        in
        match T.check ~store_dir loaded with
        | Ok status -> status
        | Error e -> failwith (T.error_to_string e)
      in
      let approve (status : T.status) now =
        match
          S.approve ~dir:store_dir ~root ~name:"demo" ~deco_version:"test" ~now
            status.digest
        with
        | Ok () -> ()
        | Error e -> failwith e
      in
      (* No record. *)
      let initial = check () in
      assert (initial.state = T.Untrusted && initial.root = root);
      assert (initial.deco_dir = Filename.concat root ".deco");
      assert (initial.trusted_at = None && initial.changes = []);
      assert (initial.warnings = []);
      (* Approved. *)
      approve initial 1000.;
      let trusted = check () in
      assert (trusted.state = T.Trusted && trusted.trusted_at = Some 1000.);
      assert (trusted.digest = initial.digest);
      (* Changed: reported against the most recent approval. *)
      write containerfile "FROM alpine\n";
      let changed = check () in
      assert (changed.state = T.Changed && changed.trusted_at = Some 1000.);
      assert (changed.changes = [ ("build/Containerfile", D.Modified) ]);
      approve changed 2000.;
      assert ((check ()).trusted_at = Some 2000.);
      (* Reverting to an earlier approval is trusted with that approval's time. *)
      write containerfile "FROM scratch\n";
      let reverted = check () in
      assert (reverted.state = T.Trusted && reverted.trusted_at = Some 1000.);
      write (Filename.concat root ".deco/notes") "";
      let added = check () in
      assert (added.state = T.Changed && added.trusted_at = Some 2000.);
      assert (
        added.changes
        = [ ("build/Containerfile", D.Modified); ("notes", D.Added) ]);
      (* An unusable record is untrusted with a warning. *)
      write (S.record_path ~dir:store_dir ~root) "corrupt";
      let corrupt = check () in
      assert (corrupt.state = T.Untrusted && List.length corrupt.warnings = 1);
      (* A symlinked .deco resolves to its target. *)
      let moved = Filename.concat temp "moved-deco" in
      Unix.rename (Filename.concat root ".deco") moved;
      Unix.symlink moved (Filename.concat root ".deco");
      assert ((check ()).deco_dir = Unix.realpath moved);
      Unix.unlink (Filename.concat root ".deco");
      Unix.rename moved (Filename.concat root ".deco");
      (* Digest errors are reported. *)
      Unix.mkfifo (Filename.concat root ".deco/pipe") 0o600;
      (match
         T.check ~store_dir
           (match Deco.Project.select ~directory:root with
           | Ok p -> (
               match Deco.Config_loader.load p with
               | Ok l -> l
               | Error _ -> assert false)
           | Error _ -> assert false)
       with
      | Error (T.Digest (D.Unsupported_entry _) as e) ->
          assert (contains (T.error_to_string e) "pipe")
      | Ok _ | Error _ -> assert false);
      (* approve digests the current .deco/ and records it. *)
      let loaded () =
        match Deco.Project.select ~directory:root with
        | Ok p -> (
            match Deco.Config_loader.load p with
            | Ok l -> l
            | Error _ -> assert false)
        | Error _ -> assert false
      in
      (match
         T.approve ~store_dir ~deco_version:"test" ~now:3000. (loaded ())
       with
      | Error (T.Digest (D.Unsupported_entry _)) -> ()
      | Ok () | Error _ -> assert false);
      Unix.unlink (Filename.concat root ".deco/pipe");
      assert (
        T.approve ~store_dir ~deco_version:"test" ~now:3000. (loaded ()) = Ok ());
      let approved = check () in
      assert (approved.state = T.Trusted && approved.trusted_at = Some 3000.);
      (match S.read ~dir:store_dir ~root with
      | Some { project_name = "demo"; approved = latest :: _; _ }, None ->
          assert (latest.deco_version = "test")
      | _ -> assert false);
      let blocked = Filename.concat temp "blocked" in
      write blocked "";
      (match
         T.approve
           ~store_dir:(Filename.concat blocked "store")
           ~deco_version:"test" ~now:3000. (loaded ())
       with
      | Error (T.Store _) -> ()
      | Ok () | Error _ -> assert false);
      (* Messages. *)
      let message = T.failure_message ~command:"assemble" added in
      assert (
        message
        = "deco: configuration for " ^ root
          ^ " has changed since it was trusted\n\
            \  modified  build/Containerfile\n\
            \  added     notes\n\
             Run 'deco trust' to review and approve it.\n");
      let untrusted = T.failure_message ~command:"exec" initial in
      assert (contains untrusted "is not trusted\n");
      assert (not (contains untrusted "--no-hooks"));
      List.iter
        (fun command ->
          assert (
            contains
              (T.failure_message ~command initial)
              ("Or run 'deco " ^ command ^ " --no-hooks'")))
        [ "stop"; "remove" ];
      assert (
        T.no_hooks_warning added
        = "deco: proceeding without hooks for configuration that is not \
           trusted (changed): " ^ root ^ "; pre_stop is skipped.\n");
      assert (
        T.no_hooks_warning { initial with root = "/p\027[2J" }
        = "deco: proceeding without hooks for configuration that is not \
           trusted (untrusted): /p\\x1b[2J; pre_stop is skipped.\n");
      assert (
        T.dry_run_note ~command:"start"
        = "Note: configuration is not trusted; 'deco start' would fail with \
           exit code 5.\n");
      assert (
        T.render_changes [ ("evil\027[2J", D.Removed) ]
        = [ "  removed   evil\\x1b[2J" ]);
      assert (
        List.map T.state_to_string [ T.Trusted; T.Changed; T.Untrusted ]
        = [ "trusted"; "changed"; "untrusted" ]))
