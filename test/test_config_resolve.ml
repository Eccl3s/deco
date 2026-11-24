let decode suffix =
  match Config.Decode.from_string ("project.name='demo'\n" ^ suffix) with
  | Ok config -> config
  | Error _ -> failwith "Invalid fixture"

let resolve config =
  match Config.Resolve.apply config with
  | Ok effective -> effective
  | Error _ -> failwith "Unexpected validation error"

let () =
  let original = decode "" in
  let before = Marshal.to_string original [] in
  let c = resolve original in
  assert (Marshal.to_string original [] = before);
  assert (resolve original = c);
  assert (c.image.name = "demo-dev-image" && c.image.tag = "latest");
  assert (Config.Effective.image_reference c.image = "demo-dev-image:latest");
  assert (c.container.name = "demo-dev-container" && c.container.shell = "sh");
  assert (c.container.workdir = None && c.mounts.workspace = None);
  assert (
    c.build.context = ".deco/build" && c.build.containerfile = "Containerfile");
  assert (
    c.build.target = None && c.build.args = [] && (not c.build.pull)
    && not c.build.no_cache);
  assert (
    c.user.mode = Config.Image && c.user.name = None && c.user.uid = None
    && c.user.gid = None);
  assert (
    c = resolve (decode "image={}\nbuild={}\nuser={}\ncontainer={}\nmounts={}"));
  let c =
    resolve
      (decode "user={name='dev',mode='keep-id'}\nmounts.workspace.target='/w'")
  in
  assert (c.user.uid = Some Config.Host && c.user.gid = Some Config.Host);
  assert (c.build.args = []);
  assert (c.container.workdir = Some "/w");
  let w = Option.get c.mounts.workspace in
  assert (w.source = "." && w.relabel = Config.No_relabel && w.target = "/w");
  let c =
    resolve
      (decode
         "image={name='custom',tag='dev'}\n\
          build={context='~/build',containerfile='Custom',target='dev',pull=true,no_cache=true,args={Z='1',A='$HOME'}}\n\
          user={mode='keep-id',name='dev',uid=42,gid=43}\n\
          container={name='custom',shell='bash',workdir='/other'}\n\
          mounts.workspace={source='$HOME',target='/w',relabel='private'}")
  in
  assert (c.image.name = "custom" && c.image.tag = "dev");
  assert (Config.Effective.image_reference c.image = "custom:dev");
  assert (
    c.build.context = "~/build"
    && c.build.containerfile = "Custom"
    && c.build.target = Some "dev");
  assert (c.build.pull && c.build.no_cache);
  assert (
    c.build.args
    = (Option.get (decode "build.args={Z='1',A='$HOME'}").build).args);
  assert (c.user.uid = Some (Config.Id 42) && c.user.gid = Some (Config.Id 43));
  assert (
    c.container.name = "custom"
    && c.container.shell = "bash"
    && c.container.workdir = Some "/other");
  assert (
    (Option.get c.mounts.workspace).source = "$HOME"
    && (Option.get c.mounts.workspace).relabel = Config.Private);
  let c = resolve (decode "user={mode='keep-id',name='dev',uid=7}") in
  assert (c.user.uid = Some (Config.Id 7) && c.user.gid = Some Config.Host);
  let c =
    resolve
      (decode
         "image.tag='latest'\n\
          user={mode='keep-id',name='dev',uid=5,gid='host'}\n\
          build={pull=false,no_cache=false}")
  in
  assert (
    c.image.tag = "latest"
    && c.user.uid = Some (Config.Id 5)
    && c.user.gid = Some Config.Host);
  assert ((not c.build.pull) && not c.build.no_cache);
  let invalid = decode "user.mode='keep-id'\ncontainer.name='!'" in
  match (Config.Resolve.apply invalid, Config.Validate.check invalid) with
  | Error actual, Error expected -> assert (actual = expected)
  | _ -> failwith "Expected unchanged validation errors"

let () =
  let c = resolve (decode "container.workdir='/explicit'") in
  assert (c.container.workdir = Some "/explicit" && c.mounts.workspace = None);
  let named n suffix =
    match
      Config.Decode.from_string
        ("project.name='" ^ String.make n 'a' ^ "'\n" ^ suffix)
    with
    | Ok c -> c
    | Error _ -> failwith "Invalid fixture"
  in
  let c = resolve (named 114 "") in
  assert (String.length c.container.name = 128);
  let invalid = named 115 "" in
  (match (Config.Resolve.apply invalid, Config.Validate.check invalid) with
  | Error actual, Error expected -> assert (actual = expected)
  | _ -> failwith "Expected derived-name failure");
  (* Image names use repository limits, not the 128-character container limit. *)
  let c = resolve (named 128 "container.name='short'") in
  assert (c.container.name = "short" && String.length c.image.name = 138)

let () =
  let source = decode "image={name='Bad',tag=''}" in
  assert (
    Config.Resolve.apply source
    = Result.map (fun () -> assert false) (Config.Validate.check source));
  let c =
    resolve (decode "image={name='REGISTRY.example:5000/team/demo',tag='Dev'}")
  in
  assert (
    c.image.name = "REGISTRY.example:5000/team/demo" && c.image.tag = "Dev")

let () =
  let none =
    {
      Config.Effective.post_create = None;
      post_start = None;
      pre_enter = None;
      pre_stop = None;
    }
  in
  let c = resolve (decode "") in
  assert (c.hooks = none);
  assert (Config.Effective.configured_hooks c.hooks = []);
  let c = resolve (decode "hooks={pre_stop='stop',post_start='go'}") in
  assert (c.hooks = { none with post_start = Some "go"; pre_stop = Some "stop" });
  assert (
    Config.Effective.configured_hooks c.hooks
    = [ ("post_start", "go"); ("pre_stop", "stop") ])

let () =
  assert ((resolve (decode "")).actions = []);
  assert (
    (resolve (decode "actions={test='t',build='b',Zed='z'}")).actions
    = [ ("Zed", "z"); ("build", "b"); ("test", "t") ])

(* Security options default to off and empty, and keep configured order. *)
let () =
  let c = (resolve (decode "")).container in
  assert (
    (not c.privileged) && c.devices = [] && c.cap_add = [] && c.cap_drop = []
    && c.security_options = []);
  let c =
    (resolve
       (decode
          "container.privileged=true\n\
           container.devices=['/dev/b','/dev/a']\n\
           container.cap_add=['MKNOD','SYS_ADMIN']\n\
           container.cap_drop=['ALL']\n\
           container.security_options=['label=disable']"))
      .container
  in
  assert c.privileged;
  assert (c.devices = [ "/dev/b"; "/dev/a" ]);
  assert (c.cap_add = [ "MKNOD"; "SYS_ADMIN" ]);
  assert (c.cap_drop = [ "ALL" ] && c.security_options = [ "label=disable" ])
