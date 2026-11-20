open Deco
module N = Named_project

let write path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

let mkdir path = Unix.mkdir path 0o700

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

(* A minimal valid project named [name] at [root]. *)
let project root name =
  mkdir root;
  mkdir (Filename.concat root ".deco");
  mkdir (Filename.concat root ".deco/build");
  write
    (Filename.concat root ".deco/config.toml")
    ("[project]\nname='" ^ name ^ "'\n");
  write (Filename.concat root ".deco/build/Containerfile") "FROM scratch\n"

let container ?project ?root id =
  `Assoc
    [
      ("Id", `String id);
      ("Names", `List [ `String (id ^ "-name") ]);
      ("State", `String "exited");
      ("Image", `String "localhost/i:latest");
      ("ImageID", `String "iid");
      ( "Labels",
        `Assoc
          (("dev.deco.managed", `String "true")
          :: List.filter_map Fun.id
               [
                 Option.map (fun p -> ("dev.deco.project", `String p)) project;
                 Option.map (fun r -> ("dev.deco.project-root", `String r)) root;
               ]) );
    ]

let contains s fragment =
  let rec loop i =
    i + String.length fragment <= String.length s
    && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let ok stdout = Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" }

(* Answer the availability probe and the managed listing; record every call. *)
let runner ?(calls = ref []) containers argv =
  calls := argv :: !calls;
  if argv = Podman_command.version then ok ""
  else if argv = Podman_command.list_managed_containers then
    ok (Yojson.Basic.to_string (`List containers))
  else failwith ("unexpected command: " ^ String.concat " " argv)

let () =
  let temp = Filename.temp_file "deco-named-project-" "" in
  Unix.unlink temp;
  mkdir temp;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let temp = Unix.realpath temp in
      let join = Filename.concat temp in
      let host_ids () = Ok User_identity.{ uid = 1000; gid = 1000 } in
      let load = Config_loader.load ~host_ids ~home_dir:temp in
      let find ?calls containers name =
        N.load ~run:(runner ?calls containers) ~load ~name ()
      in
      let alpha = join "alpha" in
      project alpha "alpha";
      let link = join "link" in
      Unix.symlink alpha link;
      (* No container carries the name. *)
      (match find [ container ~project:"other" ~root:alpha "c0" ] "alpha" with
      | Error (N.No_match { name = "alpha"; invalid_roots = [] }) as error ->
          assert (
            contains (N.error_to_string (Result.get_error error)) "deco list")
      | _ -> assert false);
      (match find [] "alpha" with
      | Error (N.No_match _) -> ()
      | _ -> assert false);
      (* A single match loads and validates the configuration; only the
         read-only probe and listing run. *)
      let calls = ref [] in
      (match
         find ~calls [ container ~project:"alpha" ~root:alpha "c1" ] "alpha"
       with
      | Ok loaded ->
          assert (loaded.project.root = alpha);
          assert (loaded.project.config_path = join "alpha/.deco/config.toml")
      | Error e -> failwith (N.error_to_string e));
      assert (
        List.rev !calls
        = [ Podman_command.version; Podman_command.list_managed_containers ]);
      (* Duplicates and a symlinked root canonicalize to one match. *)
      (match
         find
           [
             container ~project:"alpha" ~root:alpha "c1";
             container ~project:"alpha" ~root:alpha "c2";
             container ~project:"alpha" ~root:link "c3";
           ]
           "alpha"
       with
      | Ok loaded -> assert (loaded.project.root = alpha)
      | Error e -> failwith (N.error_to_string e));
      (match find [ container ~project:"alpha" ~root:link "c3" ] "alpha" with
      | Ok loaded -> assert (loaded.project.root = alpha)
      | Error e -> failwith (N.error_to_string e));
      (* Containers without a root label, or with an empty or relative one, do
         not take part in selection. The relative label names a directory that
         exists from the current directory and must still not be resolved. *)
      Sys.chdir temp;
      (match
         find
           [
             container ~project:"alpha" "c4";
             container ~project:"alpha" ~root:"" "c5";
             container ~project:"alpha" ~root:"second" "c12";
             container ~project:"alpha" ~root:alpha "c1";
           ]
           "alpha"
       with
      | Ok _ -> ()
      | Error e -> failwith (N.error_to_string e));
      (match find [ container ~project:"alpha" "c4" ] "alpha" with
      | Error (N.No_match { invalid_roots = []; _ }) -> ()
      | _ -> assert false);
      (* Distinct roots are ambiguous, reported sorted. *)
      let second = join "second" in
      project second "alpha";
      (* Only invalid root labels: reported, and suggests --project-dir. *)
      (match
         find
           [
             container ~project:"alpha" ~root:"second" "c12";
             container ~project:"alpha" ~root:"" "c5";
             container ~project:"alpha" ~root:"second" "c13";
           ]
           "alpha"
       with
      | Error (N.No_match { invalid_roots; _ }) as error ->
          assert (invalid_roots = [ ""; "second" ]);
          assert (
            contains
              (N.error_to_string (Result.get_error error))
              "--project-dir")
      | _ -> assert false);
      (match
         find
           [
             container ~project:"alpha" ~root:second "c6";
             container ~project:"alpha" ~root:alpha "c1";
           ]
           "alpha"
       with
      | Error (N.Ambiguous { name = "alpha"; roots }) as error ->
          assert (roots = [ alpha; second ]);
          let message = N.error_to_string (Result.get_error error) in
          assert (contains message "--project-dir")
      | _ -> assert false);
      (* A deleted root is reported as recorded. *)
      let gone = join "gone" in
      (match find [ container ~project:"gone" ~root:gone "c7" ] "gone" with
      | Error (N.Root { root; error = Project.Filesystem_error _; _ }) ->
          assert (root = gone)
      | _ -> assert false);
      (* A root that is a file, or a directory without a configuration. *)
      let file = join "file" in
      write file "";
      (match find [ container ~project:"file" ~root:file "c8" ] "file" with
      | Error (N.Root { error = Project.Not_directory _; _ }) -> ()
      | _ -> assert false);
      let empty = join "empty" in
      mkdir empty;
      (match find [ container ~project:"empty" ~root:empty "c9" ] "empty" with
      | Error (N.Root { error = Project.Missing_config _; _ }) -> ()
      | _ -> assert false);
      (* A root whose configuration names another project. *)
      (match find [ container ~project:"beta" ~root:alpha "c10" ] "beta" with
      | Error (N.Name_mismatch { name = "beta"; root; configured = "alpha"; _ })
        ->
          assert (root = alpha)
      | _ -> assert false);
      (* A different project is a mismatch even when its configuration would
         fail decoding or validation. *)
      let other = join "other" in
      project other "other";
      write
        (Filename.concat other ".deco/config.toml")
        "[project]\nname='other'\nunknown=1\n";

      (match find [ container ~project:"beta" ~root:other "c14" ] "beta" with
      | Error (N.Name_mismatch { configured = "other"; root; _ }) as error ->
          assert (root = other);
          assert (
            contains
              (N.error_to_string (Result.get_error error))
              "--project-dir")
      | _ -> assert false);
      (* The matching name with a schema error reports the full diagnostics. *)
      write
        (Filename.concat other ".deco/config.toml")
        "[project]\nname='beta'\nunknown=1\n";
      (match find [ container ~project:"beta" ~root:other "c14" ] "beta" with
      | Error (N.Config (Config_loader.Decode_errors _)) -> ()
      | _ -> assert false);
      (* The name is checked again after loading, so a loader that returns
         another project's configuration is still rejected. *)
      write
        (Filename.concat other ".deco/config.toml")
        "[project]\nname='beta'\n";
      let other_project =
        { Project.root = alpha; config_path = join "alpha/.deco/config.toml" }
      in
      (match
         N.load
           ~run:(runner [ container ~project:"beta" ~root:other "c14" ])
           ~load:(fun _ -> load other_project)
           ~name:"beta" ()
       with
      | Error (N.Name_mismatch { configured = "alpha"; _ }) -> ()
      | _ -> assert false);
      (* An invalid configuration at the root fails validation. *)
      let broken = join "broken" in
      project broken "broken";
      write (Filename.concat broken ".deco/config.toml") "not valid toml =";
      (match
         find [ container ~project:"broken" ~root:broken "c11" ] "broken"
       with
      | Error (N.Config _) -> ()
      | _ -> assert false);
      (* Podman unavailable: no listing is attempted. *)
      let missing argv =
        assert (argv = Podman_command.version);
        Error
          {
            Process.operation = "launch";
            message = "podman: command not found";
          }
      in
      (match N.load ~run:missing ~load ~name:"alpha" () with
      | Error (N.Podman (Podman.Unavailable _)) -> ()
      | _ -> assert false);
      (* A listing that cannot launch is also unavailable; a failing or
         malformed listing is not. *)
      let listing result argv =
        if argv = Podman_command.version then ok "" else result
      in
      (match
         N.load
           ~run:
             (listing
                (Error
                   {
                     Process.operation = "launch";
                     message = "podman: command not found";
                   }))
           ~load ~name:"alpha" ()
       with
      | Error (N.Podman (Podman.Unavailable _)) -> ()
      | _ -> assert false);
      (match
         N.load
           ~run:
             (listing
                (Ok
                   {
                     Process.status = Unix.WEXITED 125;
                     stdout = "";
                     stderr = "boom";
                   }))
           ~load ~name:"alpha" ()
       with
      | Error (N.Podman (Podman.Runtime _)) -> ()
      | _ -> assert false);
      match N.load ~run:(listing (ok "nope")) ~load ~name:"alpha" () with
      | Error (N.Podman (Podman.Invalid_response _)) -> ()
      | _ -> assert false)
