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

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Unix.realpath path

(* A project root with the default layout. *)
let project parent name =
  let root = Filename.concat parent name in
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".deco") 0o700;
  Unix.mkdir (Filename.concat root ".deco/build") 0o700;
  write (Filename.concat root ".deco/config.toml") "project.name='demo'\n";
  write (Filename.concat root ".deco/build/Containerfile") "FROM scratch\n";
  root

let compute ?(contents = "project.name='demo'\n") ?containerfile root =
  let containerfile =
    Option.value containerfile
      ~default:(Filename.concat root ".deco/build/Containerfile")
  in
  D.compute
    ~deco_dir:(Filename.concat root ".deco")
    ~config:(Filename.concat root ".deco/config.toml", contents)
    ~containerfile

let digest ?contents ?containerfile root =
  match compute ?contents ?containerfile root with
  | Ok t -> t
  | Error error -> failwith (D.error_to_string error)

let paths (t : D.t) = List.map (fun (entry : D.entry) -> entry.path) t.entries

let () =
  let r = D.relative_to in
  assert (r ~dir:"/p/.deco" "/p/.deco/config.toml" = Some "config.toml");
  assert (r ~dir:"/p/.deco" "/p/.deco/build/x" = Some "build/x");
  assert (r ~dir:"/p/.deco" "/p/.deco" = None);
  assert (r ~dir:"/p/.deco" "/p/.decoy/x" = None);
  assert (r ~dir:"/p/.deco" "/p/x" = None);
  assert (r ~dir:"/" "/config.toml" = Some "config.toml");
  assert (r ~dir:"/" "/etc/x" = Some "etc/x");
  assert (r ~dir:"/" "/" = None)

(* Known answer: changing the record encoding or ordering would silently
   invalidate every stored approval. The expected values were computed
   independently, by assembling the same record stream in Python and hashing it
   with [b2sum -l 256]. *)
let () =
  let temp = temp_dir "deco-trust-digest-kat-" in
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let root = project temp "kat" in
      Unix.symlink "build/Containerfile" (Filename.concat root ".deco/link");
      let t = digest ~contents:"project.name='kat'\n" root in
      assert (
        t.digest
        = "blake2b-256:c2ad0031232e2e469f85799a4f5d1527620e0af46bbc4922c3a9154f49af924b");
      assert (
        paths t = [ "build"; "build/Containerfile"; "config.toml"; "link" ]);
      assert (
        (List.nth t.entries 3).digest
        = "blake2b-256:954b8b85f992de1ebb342d747bed592f5b77fa856ac41f1b38683434106f0d55"))

let () =
  let temp = temp_dir "deco-trust-digest-" in
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let root = project temp "one" in
      let first = digest root in
      (* Format and determinism. *)
      assert (String.starts_with ~prefix:"blake2b-256:" first.digest);
      assert (String.length first.digest = String.length "blake2b-256:" + 64);
      assert (digest root = first);
      assert (paths first = [ "build"; "build/Containerfile"; "config.toml" ]);
      (* The parsed bytes stand in for the configuration file on disk. *)
      write (Filename.concat root ".deco/config.toml") "changed on disk\n";
      assert ((digest root).digest = first.digest);
      assert ((digest ~contents:"changed on disk\n" root).digest <> first.digest);
      write (Filename.concat root ".deco/config.toml") "project.name='demo'\n";
      (* Each kind of change alters the digest and is reported. *)
      let changed before (after : D.t) expected =
        assert (after.digest <> before.D.digest);
        assert (
          D.diff ~approved:before.entries ~current:after.entries = expected)
      in
      write (Filename.concat root ".deco/build/Containerfile") "FROM alpine\n";
      changed first (digest root) [ ("build/Containerfile", D.Modified) ];
      write (Filename.concat root ".deco/build/Containerfile") "FROM scratch\n";
      assert (digest root = first);
      Unix.mkdir (Filename.concat root ".deco/empty") 0o700;
      changed first (digest root) [ ("empty", D.Added) ];
      Unix.rmdir (Filename.concat root ".deco/empty");
      let link = Filename.concat root ".deco/link" in
      Unix.symlink "build/Containerfile" link;
      let linked = digest root in
      changed first linked [ ("link", D.Added) ];
      Unix.unlink link;
      Unix.symlink "config.toml" link;
      changed linked (digest root) [ ("link", D.Modified) ];
      Unix.unlink link;
      assert (digest root = first);
      Unix.unlink (Filename.concat root ".deco/build/Containerfile");
      let without =
        digest ~containerfile:(Filename.concat root ".deco/config.toml") root
      in
      assert (
        D.diff ~approved:first.entries ~current:without.entries
        = [ ("build/Containerfile", D.Removed) ]);
      write (Filename.concat root ".deco/build/Containerfile") "FROM scratch\n";
      assert (D.diff ~approved:first.entries ~current:first.entries = []);
      (* Path and content boundaries cannot be shifted. *)
      let a = project temp "a" and b = project temp "b" in
      write (Filename.concat a ".deco/a") "bc";
      write (Filename.concat b ".deco/ab") "c";
      assert ((digest a).digest <> (digest b).digest);
      (* Special files make the digest uncomputable. *)
      let fifo = Filename.concat root ".deco/pipe" in
      Unix.mkfifo fifo 0o600;
      (match compute root with
      | Error (D.Unsupported_entry path) -> assert (path = fifo)
      | Ok _ | Error (D.Filesystem _) -> assert false);
      Unix.unlink fifo;
      (* A Containerfile outside .deco is covered by its canonical path. *)
      let outside = Filename.concat root "Containerfile" in
      write outside "FROM scratch\n";
      let external_file = digest ~containerfile:outside root in
      assert (List.mem outside (paths external_file));
      write outside "FROM alpine\n";
      changed external_file
        (digest ~containerfile:outside root)
        [ (outside, D.Modified) ];
      (* A symlinked configuration outside .deco is covered by its target, using
         the parsed bytes rather than a second read. *)
      let real = Filename.concat root "real.toml" in
      write real "on disk\n";
      Unix.unlink (Filename.concat root ".deco/config.toml");
      Unix.symlink "../real.toml" (Filename.concat root ".deco/config.toml");
      let symlinked = digest ~contents:"parsed\n" root in
      assert (List.mem real (paths symlinked));
      assert (List.mem "config.toml" (paths symlinked));
      changed symlinked
        (digest ~contents:"edited\n" root)
        [ (real, D.Modified) ];
      (* One record when the configuration and Containerfile coincide. *)
      let same = digest ~contents:"parsed\n" ~containerfile:real root in
      assert (List.length (List.filter (( = ) real) (paths same)) = 1);
      (* A symlinked configuration inside .deco overrides its target. *)
      Unix.unlink (Filename.concat root ".deco/config.toml");
      write (Filename.concat root ".deco/real.toml") "on disk\n";
      Unix.symlink "real.toml" (Filename.concat root ".deco/config.toml");
      let inner = digest ~contents:"parsed\n" root in
      write (Filename.concat root ".deco/real.toml") "parsed\n";
      assert ((digest ~contents:"parsed\n" root).digest = inner.digest);
      (* Missing paths are filesystem errors. *)
      match
        D.compute
          ~deco_dir:(Filename.concat temp "missing/.deco")
          ~config:(Filename.concat temp "missing/.deco/config.toml", "")
          ~containerfile:outside
      with
      | Error (D.Filesystem message) -> assert (message <> "")
      | Ok _ | Error (D.Unsupported_entry _) -> assert false)
