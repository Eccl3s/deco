let decode text =
  match Config.Decode.from_string text with
  | Ok value -> value
  | Error _ -> failwith "Invalid test TOML"

let config suffix = decode ("project.name='demo'\n" ^ suffix)
let valid value = assert (Config.Validate.check value = Ok ())

let errors value =
  match Config.Validate.check value with
  | Error errors ->
      assert (errors <> []);
      errors
  | Ok () -> failwith "Expected validation error"

let () =
  valid (config "");
  List.iter
    (fun suffix -> valid (config suffix))
    [
      "user={mode='keep-id',name='dev',uid=5}";
      "container={shell='sh',workdir='/'}";
      "container={shell='/bin/sh',workdir='/workspace//src/'}";
      "mounts.workspace.target='/workspace'";
      "build.args={A='',_A1='$HOME',user_uid='literal'}";
      "user={mode='image'}";
    ];
  List.iter
    (fun suffix -> ignore (errors (config suffix)))
    [
      "container.name='-bad'";
      "container.workdir='relative'";
      "container.workdir='/a/./b'";
      "container.workdir='/a/../b'";
      "container.shell='  '";
      "container.shell='bin/sh'";
      "mounts.workspace.target=''";
      "build.args.'bad.key'=''";
      "build.args.USER_NAME=''";
      "build.args.USER_UID=''";
      "build.args.USER_GID=''";
      "user.mode='keep-id'";
      "user={mode='keep-id',name='  '}";
      "user.name='dev'";
      "user={mode='image',name=''}";
    ];
  List.iter
    (fun name -> ignore (errors (decode ("project.name='" ^ name ^ "'"))))
    [ ""; "  "; "-bad"; "bad!"; "é"; String.make 129 'a' ];
  List.iter
    (fun name ->
      valid
        (decode
           ("project.name='" ^ name
          ^ "'\ncontainer.name='short'\nimage.name='valid'")))
    [ "a"; "0"; "A.b_c-d"; String.make 128 'a' ];
  let c = config "user={}\ncontainer={}\nmounts={}" in
  let before = Marshal.to_string c [] in
  valid c;
  assert (Marshal.to_string c [] = before);
  let es =
    errors
      (config
         "container={name='!',shell=''}\n\
          user.mode='keep-id'\n\
          build.args.'a.b'=''")
  in
  assert (List.length es = 4);
  let paths = List.map (fun (e : Config.Validate.error) -> e.path) es in
  assert (
    paths
    = [
        [ "build"; "args"; "a.b" ];
        [ "container"; "name" ];
        [ "container"; "shell" ];
        [ "user"; "name" ];
      ]);
  assert (
    String.starts_with ~prefix:"build.args.\"a.b\":"
      (Config.Validate.error_to_string (List.hd es)));
  assert (
    Config.Validate.error_to_string { path = []; message = "problem" }
    = "problem")

let () =
  ignore (errors (config "container.shell='/bin/../sh'"));
  ignore (errors (config "build.args.''='x'"));
  (* Image syntax is checked; identity bounds remain deferred. *)
  ignore (errors (config "image={tag=''}"));
  ignore (errors (config "user={mode='image',uid=1000}"));
  (* Lexical paths need only be absolute and exclude dot components. *)
  valid (config "container={shell='/',workdir='/a//b/'}")

let () =
  let named n suffix =
    decode ("project.name='" ^ String.make n 'a' ^ "'\n" ^ suffix)
  in
  List.iter
    (fun suffix ->
      valid (named 114 suffix);
      List.iter
        (fun n ->
          match errors (named n suffix) with
          | [ e ] ->
              assert (e.path = [ "container"; "name" ]);
              assert (
                String.starts_with
                  ~prefix:"Derived container name exceeds 128 characters"
                  e.message)
          | _ -> failwith "Expected derived-name error")
        [ 115; 128 ])
    [ ""; "container={}"; "container.shell='sh'" ];
  valid (named 128 "container.name='short'\nimage.name='valid'");
  ignore (errors (named 128 "container.name='!'"));
  match errors (decode "project.name='-invalid'") with
  | [ e ] -> assert (e.path = [ "project"; "name" ])
  | _ -> failwith "Unexpected cascading diagnostic"

let () =
  let image name = config ("image.name='" ^ name ^ "'") in
  List.iter
    (fun name -> valid (image name))
    [
      "demo";
      "team/demo";
      "localhost/demo";
      "REGISTRY.example:5000/team/demo";
      "127.0.0.1:5000/demo";
      "a.b_c__d---e";
      String.make 255 'a';
      "example.org/" ^ String.make 243 'a';
    ];
  List.iter
    (fun name -> ignore (errors (image name)))
    [
      "";
      "Demo";
      "a/";
      "/a";
      "a//b";
      "a___b";
      "a_-b";
      "a-_b";
      "a..b";
      "a-";
      "a:tag";
      "a@sha256:abc";
      "https://example.org/a";
      "docker://a";
      "a b";
      "é";
      "host:port/a";
      "[::1]:5000/a";
      String.make 256 'a';
      "example.org/" ^ String.make 244 'a';
    ];
  List.iter
    (fun tag -> valid (config ("image.tag='" ^ tag ^ "'")))
    [ "A"; "_tag"; "v1.0-dev"; String.make 128 'a' ];
  List.iter
    (fun tag -> ignore (errors (config ("image.tag='" ^ tag ^ "'"))))
    [ ""; " "; "-a"; ".a"; "a/b"; "a:b"; String.make 129 'a' ];
  assert (List.length (errors (config "image={name='Bad',tag=''}")) = 2);
  ignore (errors (decode "project.name='Demo'"));
  valid (decode "project.name='Demo'\nimage.name='demo'")

(* Action names match [A-Za-z][A-Za-z0-9_-]* and are case-sensitive;
   commands must not be blank or contain NUL bytes. *)
let () =
  List.iter
    (fun suffix -> valid (config suffix))
    [
      "actions={test='make test',Test='make Test',a_b-c9='x'}";
      "actions={}";
      "[actions]\ndev = 'npm run dev'";
    ];
  List.iter
    (fun (suffix, name, message) ->
      match errors (config suffix) with
      | [ { path; message = actual } ] ->
          assert (path = [ "actions"; name ]);
          if actual <> message then failwith actual
      | _ -> failwith ("Expected one error: " ^ suffix))
    [
      ( "actions={'1x'='x'}",
        "1x",
        "Expected an action name matching [A-Za-z][A-Za-z0-9_-]*" );
      ( "actions={'a.b'='x'}",
        "a.b",
        "Expected an action name matching [A-Za-z][A-Za-z0-9_-]*" );
      ( "actions={'-x'='x'}",
        "-x",
        "Expected an action name matching [A-Za-z][A-Za-z0-9_-]*" );
      ( "actions={''='x'}",
        "",
        "Expected an action name matching [A-Za-z][A-Za-z0-9_-]*" );
      ("actions={test=''}", "test", "Must not be blank");
      ("actions={test='  '}", "test", "Must not be blank");
      ("actions={test=\"a\\u0000b\"}", "test", "Must not contain NUL bytes");
    ]

(* Container security options follow the spec's syntax rules. *)
let () =
  List.iter
    (fun suffix -> valid (config suffix))
    [
      "container.privileged=true";
      "container.devices=['/dev/fuse','/dev/a:/dev/b','/dev/a:/b:rwm','/x:/y:m']";
      "container.cap_add=['SYS_ADMIN','net-admin','CAP_9']";
      "container.cap_drop=['ALL']";
      "container.security_options=['label=disable','no-new-privileges']";
      "container={devices=[],cap_add=[],cap_drop=[],security_options=[]}";
    ];
  List.iter
    (fun (suffix, path) ->
      match Config.Validate.check (config suffix) with
      | Error [ e ] -> assert (e.path = [ "container"; path ])
      | _ -> failwith suffix)
    [
      ("container.devices=['']", "devices[0]");
      ("container.devices=['dev/fuse']", "devices[0]");
      ("container.devices=['/dev/a','dev/b']", "devices[1]");
      ("container.devices=['/dev/a:b']", "devices[0]");
      ("container.devices=['/dev/a:']", "devices[0]");
      ("container.devices=['/dev/a:/b:']", "devices[0]");
      ("container.devices=['/dev/a:/b:rx']", "devices[0]");
      ("container.devices=['/dev/a:/b:rr']", "devices[0]");
      ("container.devices=['/dev/a:/b:rw:m']", "devices[0]");
      ("container.cap_add=['']", "cap_add[0]");
      ("container.cap_add=['NET ADMIN']", "cap_add[0]");
      ("container.cap_drop=['ALL','SYS.ADMIN']", "cap_drop[1]");
      ("container.security_options=['']", "security_options[0]");
      ("container.security_options=[\"a\\u0000b\"]", "security_options[0]");
      ("container.devices=[\"/dev/a\\u0000b\"]", "devices[0]");
    ]

(* Environment variable names follow [A-Za-z_][A-Za-z0-9_]*; values are literal
   but must not contain NUL; env file paths must not be blank. *)
let () =
  List.iter
    (fun suffix -> valid (config suffix))
    [
      "container.environment={NODE_ENV='development',_A1='$HOME',empty=''}";
      "container.env_files=['.env','~/x.env','/abs/x.env']";
      "container={environment={},env_files=[]}";
    ];
  List.iter
    (fun (suffix, path) ->
      match Config.Validate.check (config suffix) with
      | Error [ e ] -> assert (e.path = "container" :: path)
      | _ -> failwith suffix)
    [
      ("container.environment.'1A'='x'", [ "environment"; "1A" ]);
      ("container.environment.'A-B'='x'", [ "environment"; "A-B" ]);
      ("container.environment.''='x'", [ "environment"; "" ]);
      ("container.environment.A=\"a\\u0000b\"", [ "environment"; "A" ]);
      ("container.env_files=['']", [ "env_files[0]" ]);
      ("container.env_files=['.env','  ']", [ "env_files[1]" ]);
      ("container.env_files=[\"a\\u0000b\"]", [ "env_files[0]" ]);
    ]
