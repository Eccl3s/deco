module S = Deco.Trust_store
module D = Deco.Trust_digest

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let write path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let perm path = (Unix.stat path).Unix.st_perm land 0o777
let env pairs name = List.assoc_opt name pairs

let digest n : D.t =
  {
    digest = Printf.sprintf "blake2b-256:%064d" n;
    entries = [ { path = "config.toml"; digest = Printf.sprintf "e%d" n } ];
  }

let ok = function Ok v -> v | Error message -> failwith message

let () =
  (* Location. *)
  assert (
    S.dir ~getenv:(env [ ("XDG_STATE_HOME", "/state"); ("HOME", "/home/u") ]) ()
    = Ok "/state/deco/trust");
  List.iter
    (fun xdg ->
      assert (
        S.dir ~getenv:(env (xdg @ [ ("HOME", "/home/u") ])) ()
        = Ok "/home/u/.local/state/deco/trust"))
    [ []; [ ("XDG_STATE_HOME", "") ]; [ ("XDG_STATE_HOME", "relative") ] ];
  (match S.dir ~getenv:(env [ ("HOME", "relative") ]) () with
  | Ok path -> assert (String.ends_with ~suffix:"/.local/state/deco/trust" path)
  | Error _ -> ());
  let name = Filename.basename (S.record_path ~dir:"/d" ~root:"/p") in
  assert (String.length name = 64 + String.length ".json");
  assert (
    S.record_path ~dir:"/d" ~root:"/p" <> S.record_path ~dir:"/d" ~root:"/q")

let () =
  let temp = Filename.temp_file "deco-trust-store-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      Unix.chmod temp 0o755;
      let dir = Filename.concat temp "state/deco/trust" in
      let root = "/home/u/project" in
      assert (S.read ~dir ~root = (None, None));
      let approve ?(root = root) n now =
        ok
          (S.approve ~dir ~root ~name:"project" ~deco_version:"0.3.0" ~now
             (digest n))
      in
      approve 1 1000.75;
      (* Created directories are private; existing ones are left alone. *)
      assert (perm temp = 0o755);
      List.iter
        (fun path -> assert (perm path = 0o700))
        [ Filename.concat temp "state"; Filename.concat temp "state/deco"; dir ];
      let path = S.record_path ~dir ~root in
      assert (perm path = 0o600);
      (match S.read ~dir ~root with
      | Some record, None -> (
          assert (record.project_root = root && record.project_name = "project");
          match record.approved with
          | [ a ] ->
              assert (a.digest = (digest 1).digest);
              assert (a.trusted_at = 1000.);
              assert (a.deco_version = "0.3.0");
              assert (a.entries = (digest 1).entries)
          | _ -> assert false)
      | _ -> assert false);
      (* Re-approving moves an approval to the front without duplicating it. *)
      approve 2 2000.;
      approve 1 3000.;
      let digests () =
        match S.read ~dir ~root with
        | Some record, None ->
            List.map (fun (a : S.approval) -> a.digest) record.approved
        | _ -> assert false
      in
      assert (digests () = [ (digest 1).digest; (digest 2).digest ]);
      (* At most max_approvals are kept, newest first. *)
      for n = 3 to 20 do
        approve n (float_of_int (n * 1000))
      done;
      let kept = digests () in
      assert (List.length kept = S.max_approvals);
      assert (List.hd kept = (digest 20).digest);
      assert (not (List.mem (digest 2).digest kept));
      (* Other roots have their own records. *)
      approve ~root:"/other" 7 1.;
      assert (fst (S.read ~dir ~root:"/other") <> None);
      assert (List.length (digests ()) = S.max_approvals);
      (* Unusable records are ignored with a warning and left untouched. *)
      let ignored contents =
        write path contents;
        (match S.read ~dir ~root with
        | None, Some warning ->
            assert (String.starts_with ~prefix:"Ignoring trust record " warning)
        | _ -> assert false);
        assert (read_file path = contents)
      in
      ignored "not json";
      ignored "[]";
      ignored "{}";
      ignored
        {|{"version":2,"project_root":"/home/u/project","project_name":"p","approved":[]}|};
      ignored
        {|{"version":1,"project_root":"/home/u/project","project_name":"p","approved":[{"digest":"d","trusted_at":"yesterday","deco_version":"v","entries":{}}]}|};
      ignored (read_file (S.record_path ~dir ~root:"/other"));
      (* Approval replaces an unusable record. *)
      approve 5 5000.;
      assert (digests () = [ (digest 5).digest ]);
      (* No temporary files are left behind. *)
      Array.iter
        (fun name -> assert (Filename.check_suffix name ".json"))
        (Sys.readdir dir);
      (* Revocation. *)
      assert (S.revoke ~dir ~root = Ok true);
      assert (S.revoke ~dir ~root = Ok false);
      assert (S.read ~dir ~root = (None, None));
      assert (fst (S.read ~dir ~root:"/other") <> None))
