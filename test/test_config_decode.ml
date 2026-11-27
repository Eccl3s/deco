let ok text =
  match Config.Decode.from_string text with
  | Ok value -> value
  | Error errors ->
      failwith
        (String.concat "\n" (List.map Config.Decode.error_to_string errors))

let bad text =
  match Config.Decode.from_string text with
  | Error errors ->
      assert (errors <> []);
      errors
  | Ok _ -> failwith "Expected rejection"

(* Lenient name lookup ignores unrelated schema errors. *)
let () =
  let name = Config.Decode.project_name in
  assert (name "[project]\nname='demo'" = Some "demo");
  assert (name "project.name='demo'\nunknown=1\n[bogus]\nx=[1]" = Some "demo");
  assert (name "[project]\ndescription='d'" = None);
  assert (name "[project]\nname=1" = None);
  assert (name "project='demo'" = None);
  assert (name "" = None);
  assert (name "not valid toml =" = None)

let () =
  let minimal = ok "[project]\nname='demo'" in
  assert (minimal.project.name = "demo" && minimal.user = None);
  let c =
    ok
      "project.name='demo'\n\
       build={pull=false,args={VERSION='22'}}\n\
       user={name='dev',mode='keep-id',uid='host',gid=1000}\n\
       mounts.workspace={target='/workspace',relabel='shared'}"
  in
  assert ((Option.get c.build).pull = Some false);
  assert ((Option.get c.user).uid = Some Config.Host);
  List.iter
    (fun text -> ignore (bad text))
    [
      "";
      "project=[]";
      "project={name=1}";
      "project={name='x',extra=true}";
      "project.name='x'\nuser.mode='root'";
      "project.name='x'\nnetwork.mdoe='host'";
      "project.name='x'\nmounts.workspace={}";
      "project.name='x'\nbuild.args.X=1";
      "project.name='x'\nproject.name='y'";
      "project = ";
      "project.name='x'\nuser.uid=999999999999999999999999999999";
    ];
  let errors =
    bad "project.name=1\ncontainer.shell=false\nbuild.pull='false'"
  in
  assert (List.length errors = 3);
  let paths =
    List.filter_map
      (function Config.Decode.Schema_error e -> Some e.path | _ -> None)
      errors
  in
  assert (
    paths
    = [ [ "build"; "pull" ]; [ "container"; "shell" ]; [ "project"; "name" ] ]);
  assert (List.length (bad "project=1") = 1);
  let c =
    ok
      "project={name='  '}\n\
       build.args={'a.b'='$HOME/~'}\n\
       user={}\n\
       container={}\n\
       mounts={}"
  in
  assert ((Option.get c.build).args = [ ("a.b", "$HOME/~") ]);
  assert ((Option.get c.user).mode = None)

let () =
  List.iter
    (fun (text, expected) ->
      let c =
        ok
          ("project.name='x'\nmounts.workspace={target='/w',relabel='" ^ text
         ^ "'}")
      in
      assert (
        (Option.get (Option.get c.mounts).workspace).relabel = Some expected))
    [
      ("shared", Config.Shared);
      ("private", Config.Private);
      ("none", Config.No_relabel);
    ];
  assert (
    (Option.get (ok "project.name='x'\nuser.mode='image'").user).mode
    = Some Config.Image);
  ignore (bad "project.name='x'\n[[build]]\npull=true");
  ignore (bad "project.name='x'\nuser.uid='1000'");
  ignore (bad "project.name='x'\nuser.uid=1.0");
  ignore (bad "project.name='x'\nmounts.workspace={target='/w',relabel='bad'}");
  let message =
    bad "project.name='x'\nbuild.args.'a.b'=1"
    |> List.hd |> Config.Decode.error_to_string
  in
  assert (String.starts_with ~prefix:"build.args.\"a.b\":" message)

let () =
  let open Config.Decode in
  (match bad "project = " with
  | [ Syntax_error { location = Some _; _ } ] -> ()
  | _ -> failwith "Expected syntax location");
  (match bad "project.name='x'\nuser.uid=999999999999999999999999999999" with
  | [ Syntax_error { location = None; message } ] ->
      assert (message = "Integer exceeds the supported OCaml int range")
  | _ -> failwith "Expected numeric parser failure");
  assert (
    error_to_string (Schema_error { path = []; message = "problem" })
    = "problem");
  let enum_error =
    bad "project.name='x'\nuser.mode='root'" |> List.hd |> error_to_string
  in
  assert (
    enum_error
    = "user.mode: Unsupported value \"root\" (expected one of: \"keep-id\", \
       \"image\")");
  List.iter
    (fun (input, path) ->
      match bad input with
      | [ Schema_error e ] -> assert (e.path = path)
      | _ -> failwith "Expected one parent error")
    [
      ("[[project]]\nname='x'", [ "project" ]);
      ("project.name='x'\nmounts={workspace='w'}", [ "mounts"; "workspace" ]);
    ];
  let errors =
    bad
      "project={description=1}\n\
       mounts.workspace={source=1,relabel='bad'}\n\
       container.shell=1"
  in
  assert (List.length errors = 6);
  List.iter
    (fun (literal, expected) ->
      let c =
        ok ("project.name='x'\nuser.uid=" ^ literal ^ "\nuser.gid=" ^ literal)
      in
      let user = Option.get c.user in
      assert (user.uid = Some (Config.Id expected));
      assert (user.gid = Some (Config.Id expected)))
    [ ("-5", -5); ("0x1F", 31); ("0o17", 15) ]

let () =
  let c =
    ok "project.name='x'\n[hooks]\npost_create='npm install'\npre_stop=''"
  in
  assert (
    c.hooks
    = Some
        {
          post_create = Some "npm install";
          post_start = None;
          pre_enter = None;
          pre_stop = Some "";
        });
  assert ((ok "project.name='x'").hooks = None);
  List.iter
    (fun (input, path) ->
      match bad ("project.name='x'\n" ^ input) with
      | [ Schema_error e ] -> assert (e.path = path)
      | _ -> failwith ("Expected one hook error: " ^ input))
    [
      ("hooks.post_start=1", [ "hooks"; "post_start" ]);
      ("hooks.post_strat='x'", [ "hooks"; "post_strat" ]);
      ("hooks='x'", [ "hooks" ]);
    ]

let () =
  let c = ok "project.name='x'\n[actions]\ntest='make test'\nb='y'" in
  assert (c.actions = Some [ ("test", "make test"); ("b", "y") ]);
  assert ((ok "project.name='x'\nactions={a='1'}").actions = Some [ ("a", "1") ]);
  assert ((ok "project.name='x'").actions = None);
  List.iter
    (fun (input, path) ->
      match bad ("project.name='x'\n" ^ input) with
      | [ Schema_error e ] -> assert (e.path = path)
      | _ -> failwith ("Expected one action error: " ^ input))
    [
      ("actions.test=1", [ "actions"; "test" ]);
      ("actions.test=['a']", [ "actions"; "test" ]);
      ("actions='x'", [ "actions" ]);
    ]

(* Container security options decode as typed values, in configured order. *)
let () =
  let decoded text =
    match Config.Decode.from_string ("project.name='x'\n" ^ text) with
    | Ok config -> Option.get config.container
    | Error _ -> failwith "Invalid fixture"
  in
  let c =
    decoded
      "container.privileged=true\n\
       container.devices=['/dev/fuse','/dev/a:/dev/b:rw']\n\
       container.cap_add=['SYS_ADMIN','MKNOD']\n\
       container.cap_drop=['ALL']\n\
       container.security_options=['label=disable']"
  in
  assert (c.privileged = Some true);
  assert (c.devices = Some [ "/dev/fuse"; "/dev/a:/dev/b:rw" ]);
  assert (c.cap_add = Some [ "SYS_ADMIN"; "MKNOD" ]);
  assert (c.cap_drop = Some [ "ALL" ]);
  assert (c.security_options = Some [ "label=disable" ]);
  let c = decoded "container.cap_drop=[]" in
  assert (c.cap_drop = Some [] && c.privileged = None && c.devices = None);
  List.iter
    (fun (text, path) ->
      match Config.Decode.from_string ("project.name='x'\n" ^ text) with
      | Error [ Config.Decode.Schema_error e ] ->
          assert (e.path = [ "container"; path ])
      | _ -> assert false)
    [
      ("container.privileged='yes'", "privileged");
      ("container.devices='/dev/fuse'", "devices");
      ("container.cap_add=[1]", "cap_add");
      ("container.cap_drop=['ALL',false]", "cap_drop");
      ("container.security_options={}", "security_options");
      ("container.env_files='.env'", "env_files");
      ("container.env_files=[1]", "env_files");
      ("container.environment=['A=1']", "environment");
    ];
  (* The environment keeps configured order; values are literal. *)
  let c =
    decoded
      "container.env_files=['b.env','a.env']\n\
       [container.environment]\n\
       ZED='$HOME'\n\
       ALPHA='a b'"
  in
  assert (c.env_files = Some [ "b.env"; "a.env" ]);
  assert (c.environment = Some [ ("ZED", "$HOME"); ("ALPHA", "a b") ]);
  (match
     Config.Decode.from_string
       "project.name='x'\ncontainer.environment.TOKEN=42"
   with
  | Error [ Config.Decode.Schema_error e ] ->
      assert (e.path = [ "container"; "environment"; "TOKEN" ])
  | _ -> assert false);
  let c = decoded "container.name='n'" in
  assert (c.env_files = None && c.environment = None)
