module C = Deco.Trust_cmd
module T = Deco.Trust

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

let count s fragment =
  let n = String.length fragment in
  let rec loop i acc =
    if i + n > String.length s then acc
    else loop (i + 1) (if String.sub s i n = fragment then acc + 1 else acc)
  in
  loop 0 0

let () =
  let temp = Filename.temp_file "deco-trust-cmd-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  let temp = Unix.realpath temp in
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let root = Filename.concat temp "project" in
      Unix.mkdir root 0o700;
      Unix.mkdir (Filename.concat root ".deco") 0o700;
      Unix.mkdir (Filename.concat root ".deco/build") 0o700;
      write (Filename.concat root ".deco/config.toml") "project.name='demo'\n";
      let containerfile = Filename.concat root ".deco/build/Containerfile" in
      write containerfile "FROM scratch\n";
      let store_dir = Filename.concat temp "store" in
      let load () =
        match Deco.Project.select ~directory:root with
        | Error e -> failwith (Deco.Project.error_to_string e)
        | Ok p -> (
            match Deco.Config_loader.load p with
            | Ok loaded -> loaded
            | Error e -> failwith (Deco.Config_loader.error_to_string e))
      in
      let state () =
        match T.check ~store_dir (load ()) with
        | Ok status -> status.state
        | Error e -> failwith (T.error_to_string e)
      in
      let prompts = ref [] in
      let run ?(interactive = false) ?(answer = fun () -> None) mode =
        let out = Buffer.create 256 and err = Buffer.create 64 in
        let result =
          C.run ~store_dir
            ~now:(fun () -> 7200.)
            ~interactive
            ~prompt:(fun question ->
              prompts := question :: !prompts;
              answer ())
            ~out:(Buffer.add_string out) ~err:(Buffer.add_string err)
            ~deco_version:"test" mode (load ())
        in
        (result, Buffer.contents out, Buffer.contents err)
      in
      let approve ?(yes = false) ?(dry_run = false) ?interactive ?answer () =
        run ?interactive ?answer (C.Approve { yes; dry_run })
      in
      (* --show and --revoke without a record. *)
      let result, out, _ = run C.Show in
      assert (result = Ok ());
      assert (contains out "State:          untrusted\n");
      assert (contains out ("Root:           " ^ root ^ "\n"));
      assert (contains out "Digest:         blake2b-256:");
      assert (contains out "Last approved:  -\n");
      assert (not (contains out "Changes:"));
      let result, out, _ = run C.Revoke in
      assert (result = Ok ());
      assert (out = "Configuration was not trusted: " ^ root ^ "\n");
      (* Outside a terminal without --yes nothing is approved. *)
      let result, out, _ = approve () in
      assert (result = Error C.Not_interactive);
      assert (contains out "\nPlanned settings");
      assert (!prompts = [] && state () = T.Untrusted);
      (* A dry run prints the review and approves nothing, even in a terminal. *)
      let result, out, _ = approve ~dry_run:true ~interactive:true () in
      assert (result = Ok () && contains out "Trust state:    untrusted");
      assert (!prompts = [] && state () = T.Untrusted);
      (* Declining, including at end of input. *)
      List.iter
        (fun answer ->
          let result, _, _ =
            approve ~interactive:true ~answer:(fun () -> answer) ()
          in
          assert (result = Error C.Declined);
          assert (state () = T.Untrusted))
        [ None; Some ""; Some "n"; Some "yess"; Some "no" ];
      assert (List.for_all (( = ) "Trust this configuration? [y/N] ") !prompts);
      (* Confirming. *)
      let result, out, _ =
        approve ~interactive:true ~answer:(fun () -> Some "  YES \n") ()
      in
      assert (result = Ok ());
      assert (String.ends_with ~suffix:("\nTrusted " ^ root ^ "\n") out);
      assert (state () = T.Trusted);
      let result, out, _ = approve ~interactive:true () in
      assert (result = Ok ());
      assert (out = "Configuration is already trusted: " ^ root ^ "\n");
      let _, out, _ = run C.Show in
      assert (contains out "State:          trusted\n");
      assert (contains out "Last approved:  1970-01-01 02:00 UTC (just now)\n");
      (* Changed: --show lists changes; --yes approves without a prompt. *)
      write containerfile "FROM alpine\n";
      let _, out, _ = run C.Show in
      assert (contains out "State:          changed\n");
      assert (contains out "Changes:\n  modified  build/Containerfile\n");
      prompts := [];
      let result, out, _ = approve ~yes:true () in
      assert (result = Ok () && !prompts = []);
      assert (contains out "Changed since the last approval");
      assert (state () = T.Trusted);
      (* .deco/ changing during review is refused. *)
      write containerfile "FROM busybox\n";
      let result, _, _ =
        approve ~interactive:true
          ~answer:(fun () ->
            write containerfile "FROM busybox:edited\n";
            Some "y")
          ()
      in
      assert (result = Error C.Changed_during_review);
      assert (state () = T.Changed);
      (* Store warnings are reported once. *)
      write (Deco.Trust_store.record_path ~dir:store_dir ~root) "corrupt";
      let result, _, err = approve ~yes:true () in
      assert (result = Ok ());
      assert (String.starts_with ~prefix:"deco: Ignoring trust record " err);
      assert (count err "Ignoring trust record" = 1);
      (* Revoking. *)
      let result, out, _ = run C.Revoke in
      assert (result = Ok () && out = "Trust revoked: " ^ root ^ "\n");
      assert (state () = T.Untrusted);
      (* Digest errors. *)
      Unix.mkfifo (Filename.concat root ".deco/pipe") 0o600;
      (match approve ~yes:true () with
      | Error (C.Trust (T.Digest _)), _, _ -> ()
      | _ -> assert false);
      Unix.unlink (Filename.concat root ".deco/pipe");
      (* An unwritable store. *)
      let blocked = Filename.concat temp "blocked" in
      write blocked "";
      match
        C.run
          ~store_dir:(Filename.concat blocked "store")
          ~out:ignore ~err:ignore ~deco_version:"test"
          (C.Approve { yes = true; dry_run = false })
          (load ())
      with
      | Error (C.Store _) -> ()
      | _ -> assert false)
