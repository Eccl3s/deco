module P = Deco.Project

let ok = function
  | Ok value -> value
  | Error e -> failwith (P.error_to_string e)

let write path =
  let ch = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out ch)
    (fun () -> output_string ch "not valid toml =")

let mkdir path = Unix.mkdir path 0o700

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let () =
  let cwd = Sys.getcwd () in
  let temp = Filename.temp_file "deco-project-" "" in
  Unix.unlink temp;
  mkdir temp;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let root = Unix.realpath temp in
      let join = Filename.concat in
      let deco = join root ".deco" in
      mkdir deco;
      let config = join deco "config.toml" in
      write config;
      let child = join root "child" in
      mkdir child;
      let nested = join child "nested" in
      mkdir nested;
      let p = ok (P.discover ~start_dir:nested) in
      assert (p.root = root && p.config_path = config);
      assert ((ok (P.select ~directory:root)).root = root);
      (match P.select ~directory:child with
      | Error (P.Missing_config _) -> ()
      | _ -> assert false);
      write (join child "config.toml");
      let child_deco = join child ".deco" in
      mkdir child_deco;
      assert ((ok (P.discover ~start_dir:nested)).root = root);
      write (join child_deco "config.toml");
      assert ((ok (P.discover ~start_dir:nested)).root = child);
      let alias = join root "alias" in
      Unix.symlink nested alias;
      assert ((ok (P.discover ~start_dir:alias)).root = child);
      Unix.unlink (join child_deco "config.toml");
      Unix.symlink config (join child_deco "config.toml");
      assert ((ok (P.select ~directory:child)).root = child);
      Unix.unlink (join child_deco "config.toml");
      Unix.symlink "absent" (join child_deco "config.toml");
      assert ((ok (P.discover ~start_dir:child)).root = root);
      Unix.unlink (join child_deco "config.toml");
      mkdir (join child_deco "config.toml");
      (match P.discover ~start_dir:child with
      | Error (P.Not_regular_file _) -> ()
      | _ -> assert false);
      Unix.rmdir (join child_deco "config.toml");
      Unix.rmdir child_deco;
      write child_deco;
      (match P.discover ~start_dir:child with
      | Error (P.Not_directory _) -> ()
      | _ -> assert false);
      Unix.unlink child_deco;
      mkdir child_deco;
      Unix.symlink "config.toml" (join child_deco "config.toml");
      (match P.discover ~start_dir:child with
      | Error (P.Filesystem_error { reason = Unix.ELOOP; _ }) -> ()
      | _ -> assert false);
      (match P.select ~directory:config with
      | Error (P.Not_directory _) -> ()
      | _ -> assert false);
      (match P.select ~directory:(join root "missing") with
      | Error (P.Filesystem_error _) -> ()
      | _ -> assert false);
      assert (
        String.length (P.error_to_string (P.Missing_config { root }))
        > String.length root);
      assert (Sys.getcwd () = cwd));
  (* Do not assume the checkout or temporary directory has no project ancestors. *)
  if not (Sys.file_exists "/.deco") then
    match P.discover ~start_dir:"/" with
    | Error (P.Not_found _) -> ()
    | _ -> assert false
