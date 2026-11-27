open Deco

let load text =
  let source = Result.get_ok (Config.Decode.from_string text) in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  ({
     ignored_paths = [];
     contents = "";
     project = { root = "/project"; config_path = "/project/.deco/config.toml" };
     source;
     effective;
     host_paths =
       {
         build_context = "/project/.deco/build";
         containerfile = "/project/.deco/build/Containerfile";
         workspace_source = None;
         env_files = [];
         protected = [];
         deco_protection = Not_applicable;
         git_protection = Not_applicable;
       };
     identity = User_identity.Image;
   }
    : Config_loader.t)

let () =
  assert (Create_settings.label = "dev.deco.create-digest");
  (* Stable, and formatted like the trust digest. *)
  let empty = Create_settings.digest [] in
  assert (empty = Create_settings.digest []);
  let prefix = "blake2b-256:" in
  assert (String.starts_with ~prefix empty);
  let hex = String.sub empty 12 (String.length empty - 12) in
  assert (String.length hex = 64);
  assert (
    String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) hex);
  (* Known answers, computed independently, guard the persisted encoding: any
     drift would make every labelled container incompatible. *)
  assert (
    empty
    = "blake2b-256:0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8");
  assert (
    Create_settings.digest [ ("container.cap_drop", "ALL") ]
    = "blake2b-256:587eb695f312145d7d6f45fef290546f139b18a17792f8612e1c98218c8f714b");
  (* Order does not matter; content does. *)
  let a = [ ("container.cap_drop", "ALL"); ("network.mode", "pasta") ] in
  assert (Create_settings.digest a = Create_settings.digest (List.rev a));
  assert (Create_settings.digest a <> empty);
  assert (
    Create_settings.digest [ ("k", "a") ]
    <> Create_settings.digest [ ("k", "b") ]);
  (* Length prefixes keep key/value boundaries distinct. *)
  assert (
    Create_settings.digest [ ("ab", "c") ]
    <> Create_settings.digest [ ("a", "bc") ]);
  assert (
    Create_settings.digest [ ("a", ""); ("b", "") ]
    <> Create_settings.digest [ ("a", "b") ]);
  (* Duplicate keys are a programming error. *)
  assert (
    match Create_settings.digest [ ("k", "a"); ("k", "b") ] with
    | _ -> false
    | exception Invalid_argument _ -> true);
  (* Settings that do not change podman create do not contribute, so this
     configuration matches a container created before the label existed. *)
  let loaded =
    load
      "project.name='example'\n\
       container.workdir='/work'\n\
       container.shell='/bin/zsh'\n\
       hooks.post_start='echo ready'\n"
  in
  assert (Create_settings.fields loaded = []);
  assert (Create_settings.of_loaded loaded = empty)

(* Security options contribute only when they change podman create. *)
let () =
  let prefixed values =
    String.concat ""
      (List.map
         (fun v ->
           let b = Bytes.create 8 in
           Bytes.set_int64_be b 0 (Int64.of_int (String.length v));
           Bytes.to_string b ^ v)
         values)
  in
  let fields text =
    Create_settings.fields (load ("project.name='x'\n" ^ text))
  in
  let empty = Create_settings.digest [] in
  List.iter
    (fun text ->
      assert (fields text = []);
      assert (
        Create_settings.of_loaded (load ("project.name='x'\n" ^ text)) = empty))
    [
      "";
      "container.privileged=false";
      "container={devices=[],cap_add=[],cap_drop=[],security_options=[]}";
    ];
  assert (
    fields
      "container.privileged=true\n\
       container.devices=['/dev/fuse','/dev/a:/dev/b']\n\
       container.cap_add=['SYS_ADMIN']\n\
       container.cap_drop=['ALL']\n\
       container.security_options=['label=disable']"
    = [
        ("container.privileged", "true");
        ("container.devices", prefixed [ "/dev/fuse"; "/dev/a:/dev/b" ]);
        ("container.cap_add", prefixed [ "SYS_ADMIN" ]);
        ("container.cap_drop", prefixed [ "ALL" ]);
        ("container.security_options", prefixed [ "label=disable" ]);
      ]);
  (* Every setting changes the digest, and so does reordering a list. *)
  let digest text =
    Create_settings.of_loaded (load ("project.name='x'\n" ^ text))
  in
  let all =
    List.map digest
      [
        "";
        "container.privileged=true";
        "container.devices=['/dev/fuse']";
        "container.cap_add=['ALL']";
        "container.cap_drop=['ALL']";
        "container.security_options=['ALL']";
        "container.cap_drop=['ALL','MKNOD']";
        "container.cap_drop=['MKNOD','ALL']";
      ]
  in
  assert (List.length (List.sort_uniq compare all) = List.length all)

(* List values are length-prefixed, so the digest does not rely on validation
   rejecting NUL: one entry containing NUL cannot collide with two entries. *)
let () =
  let base = load "project.name='x'\n" in
  let with_options security_options =
    Create_settings.of_loaded
      {
        base with
        effective =
          {
            base.effective with
            container = { base.effective.container with security_options };
          };
      }
  in
  assert (with_options [ "a"; "b" ] <> with_options [ "a\000b" ]);
  assert (with_options [ "ab" ] <> with_options [ "a"; "b" ])

(* Env files (canonical paths) and the environment (name, value pairs)
   contribute in configured order, only when configured. *)
let () =
  let prefixed values =
    String.concat ""
      (List.map
         (fun v ->
           let b = Bytes.create 8 in
           Bytes.set_int64_be b 0 (Int64.of_int (String.length v));
           Bytes.to_string b ^ v)
         values)
  in
  let load ?(env_files = []) text =
    let loaded = load ("project.name='x'\n" ^ text) in
    { loaded with host_paths = { loaded.host_paths with env_files } }
  in
  assert (
    Create_settings.fields (load "container={environment={},env_files=[]}") = []);
  assert (
    Create_settings.fields
      (load
         ~env_files:[ "/project/b.env"; "/host/a.env" ]
         "container.env_files=['b.env','~/a.env']\n\
          container.environment={ZED='z',ALPHA=''}")
    = [
        ("container.env_files", prefixed [ "/project/b.env"; "/host/a.env" ]);
        ("container.environment", prefixed [ "ZED"; "z"; "ALPHA"; "" ]);
      ]);
  let digest ?env_files text =
    Create_settings.of_loaded (load ?env_files text)
  in
  let all =
    [
      digest "";
      digest "container.environment.A='1'";
      digest "container.environment.A='2'";
      digest "container.environment.B='1'";
      digest "container.environment={A='1',B='2'}";
      digest "container.environment={B='2',A='1'}";
      (* Name/value boundaries are length-prefixed. *)
      digest "container.environment={A='B',C=''}";
      digest "container.environment={A='',BC=''}";
      digest ~env_files:[ "/a.env" ] "container.env_files=['/a.env']";
      digest ~env_files:[ "/b.env" ] "container.env_files=['/b.env']";
      digest ~env_files:[ "/a.env"; "/b.env" ]
        "container.env_files=['/a.env','/b.env']";
      digest ~env_files:[ "/b.env"; "/a.env" ]
        "container.env_files=['/b.env','/a.env']";
    ]
  in
  assert (List.length (List.sort_uniq compare all) = List.length all);
  (* Only resolved paths count: two spellings of one file give one digest. *)
  assert (
    digest ~env_files:[ "/project/.env" ] "container.env_files=['.env']"
    = digest ~env_files:[ "/project/.env" ]
        "container.env_files=['/project/.env']")
