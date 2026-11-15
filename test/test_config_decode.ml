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
      "project.name='x'\nnetwork.mode='host'";
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
      assert (
        String.starts_with ~prefix:"TOML parser could not decode a value: "
          message)
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
