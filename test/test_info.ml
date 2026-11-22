open Deco

let contains s fragment =
  let rec loop i =
    i + String.length fragment <= String.length s
    && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let () =
  let load text =
    let source = Result.get_ok (Config.Decode.from_string text) in
    let effective = Result.get_ok (Config.Resolve.apply source) in
    ({
       ignored_paths = [];
       contents = "";
       project =
         { root = "/project"; config_path = "/project/.deco/config.toml" };
       source;
       effective;
       host_paths =
         {
           build_context = "/project/.deco/build";
           containerfile = "/project/.deco/build/Containerfile";
           workspace_source = None;
         };
       identity = User_identity.Image;
     }
      : Config_loader.t)
  in
  let loaded = load "[project]\nname = 'example'\ndescription = 'Demo'\n" in
  let labels project =
    `Assoc
      [
        ("dev.deco.managed", `String "true");
        ("dev.deco.project", `String project);
        ("dev.deco.project-root", `String "/project");
      ]
  in
  let container ?(project = "example") ?(init = true) ?(image = "iid")
      ?(workdir = "/") ?(created = `String "2026-11-12T09:30:45+01:00")
      ?(mounts = []) state =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String "cid");
               ("Image", `String image);
               ("Created", created);
               ("State", `Assoc [ ("Status", `String state) ]);
               ( "Config",
                 `Assoc
                   [
                     ("Labels", labels project); ("WorkingDir", `String workdir);
                   ] );
               ( "HostConfig",
                 `Assoc [ ("UsernsMode", `String ""); ("Init", `Bool init) ] );
               ("Mounts", `List mounts);
             ];
         ])
  in
  let image ?(project = "example") ?(workdir = "/")
      ?(created = `String "2026-11-11T09:14:02.440792071Z") () =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String "iid");
               ("Created", created);
               ("Labels", labels project);
               ("Config", `Assoc [ ("WorkingDir", `String workdir) ]);
             ];
         ])
  in
  let ok ?(status = Unix.WEXITED 0) stdout =
    Ok { Process.status; stdout; stderr = "" }
  in
  let missing = ok ~status:(Unix.WEXITED 125) "" in
  let version_json = Podman_command.version_json in
  let image_inspect =
    Podman_command.inspect "image" "example-dev-image:latest"
  in
  let container_inspect =
    Podman_command.inspect "container" "example-dev-container"
  in
  (* A fake Podman: inspections answer [image_result] and [container_result];
     a failed inspection reports absence through [exists]. *)
  let fake ?(version = ok {|{"Client":{"Version":"5.7.0"}}|})
      ?(image_result = ok (image ())) ?(info = ok "{}") ?(probe_version = ok "")
      container_result =
    let calls = ref [] in
    let run argv =
      calls := argv :: !calls;
      if argv = version_json then version
      else if argv = image_inspect then image_result
      else if argv = container_inspect then container_result
      else if argv = Podman_command.exists "image" "example-dev-image:latest"
      then ok ~status:(Unix.WEXITED 1) ""
      else if argv = Podman_command.exists "container" "example-dev-container"
      then ok ~status:(Unix.WEXITED 1) ""
      else if argv = Podman_command.version then probe_version
      else if argv = Podman_command.info then info
      else failwith ("Unexpected command: " ^ String.concat " " argv)
    in
    (run, calls)
  in
  let no_probe () = Some true in
  let changed : Trust.status =
    {
      state = Trust.Changed;
      root = "/project";
      deco_dir = "/project/.deco";
      digest = { digest = "blake2b-256:abc"; entries = [] };
      trusted_at = Some 1794388442.;
      changes =
        [
          ("config.toml", Trust_digest.Modified); ("notes", Trust_digest.Added);
        ];
      warnings = [];
    }
  in
  let collect ?(loaded = loaded) ?(probe = no_probe) ?(trust = Some changed) run
      =
    match Info.collect ~run ~probe ~trust loaded with
    | Ok (report, None) -> report
    | Ok (_, Some reason) -> failwith ("unexpectedly unavailable: " ^ reason)
    | Error _ -> failwith "unexpected error"
  in
  (* Everything present, owned, compatible and running. *)
  let run, _ = fake (ok (container "running")) in
  let r = collect run in
  assert (r.project.name = "example");
  assert (r.project.description = Some "Demo");
  assert (r.project.root = "/project");
  assert (r.project.config = "/project/.deco/config.toml");
  assert (r.podman = { available = true; version = Some "5.7.0" });
  assert (r.image.id = Some "iid" && r.image.exists = Some true);
  assert (r.image.owned = Some true);
  assert (
    Option.map Timestamp.to_rfc3339 r.image.created
    = Some "2026-11-11T09:14:02Z");
  assert (r.container.id = Some "cid" && r.container.exists = Some true);
  assert (r.container.state = Some "running");
  assert (r.container.podman_state = Some "running");
  assert (
    Option.map Timestamp.to_rfc3339 r.container.created
    = Some "2026-11-12T08:30:45Z");
  assert (r.container.owned = Some true);
  assert (r.container.compatible = Some true);
  assert (r.container.incompatibilities = []);
  assert (r.runtime = { user_mode = "image"; workdir = Some "/"; shell = "sh" });
  assert (r.mounts = [] && r.dns = [] && r.ports = []);
  assert (r.hooks = [] && r.actions = []);
  (* Configured hooks are listed by name in execution order. *)
  let hooked =
    load
      "[project]\n\
       name = 'example'\n\
       [hooks]\n\
       pre_stop = 'b'\n\
       post_create = 'a'\n\
       pre_enter = 'c'\n"
  in
  let run, _ = fake (ok (container "running")) in
  assert (
    (collect ~loaded:hooked run).hooks
    = [ "post_create"; "pre_enter"; "pre_stop" ]);
  assert (
    r.trust
    = Some
        {
          state = "changed";
          digest = "blake2b-256:abc";
          trusted_at = Some 1794388442.;
          changed = [ ("config.toml", "modified"); ("notes", "added") ];
        });
  (* Exact JSON for the complete report. *)
  let expected =
    {|{
  "project": {
    "name": "example",
    "description": "Demo",
    "root": "/project",
    "config": "/project/.deco/config.toml"
  },
  "trust": {
    "state": "changed",
    "digest": "blake2b-256:abc",
    "trusted_at": "2026-11-11T09:14:02Z",
    "changed": [
      { "path": "config.toml", "change": "modified" },
      { "path": "notes", "change": "added" }
    ]
  },
  "podman": { "available": true, "version": "5.7.0" },
  "image": {
    "name": "example-dev-image",
    "tag": "latest",
    "id": "iid",
    "exists": true,
    "created": "2026-11-11T09:14:02Z",
    "owned": true
  },
  "container": {
    "name": "example-dev-container",
    "id": "cid",
    "exists": true,
    "state": "running",
    "podman_state": "running",
    "created": "2026-11-12T08:30:45Z",
    "owned": true,
    "compatible": true,
    "incompatibilities": []
  },
  "runtime": { "user_mode": "image", "workdir": "/", "shell": "sh" },
  "mounts": [],
  "dns": [],
  "ports": [],
  "hooks": [],
  "actions": []
}
|}
  in
  let json = Info.render_json r in
  if json <> expected then failwith json;
  (* Untrusted: no approval time and no changes. *)
  let run, _ = fake (ok (container "running")) in
  let untrusted =
    collect
      ~trust:
        (Some
           {
             changed with
             state = Trust.Untrusted;
             trusted_at = None;
             changes = [];
           })
      run
  in
  let json = Info.render_json untrusted in
  assert (
    contains json
      {|"trust": {
    "state": "untrusted",
    "digest": "blake2b-256:abc",
    "trusted_at": null,
    "changed": []
  },|});
  (* Reads are batched when read_many is supplied. *)
  let run, _ = fake (ok (container "running")) in
  let batches = ref [] in
  let read_many commands =
    batches := commands :: !batches;
    List.map run commands
  in
  (match Info.collect ~run ~read_many ~probe:no_probe ~trust:None loaded with
  | Ok (_, None) -> ()
  | _ -> assert false);
  assert (!batches = [ [ version_json; image_inspect; container_inspect ] ]);
  (* Missing resources are reported, not fatal. *)
  let run, _ = fake ~image_result:missing (ok (container "exited")) in
  let r = collect run in
  assert (r.image.exists = Some false && r.image.id = None);
  assert (r.image.created = None && r.image.owned = None);
  assert (r.container.exists = Some true && r.container.owned = Some true);
  assert (r.container.compatible = None && r.container.incompatibilities = []);
  assert (r.runtime.workdir = None);
  let run, _ = fake missing in
  let r = collect run in
  assert (r.image.exists = Some true && r.container.exists = Some false);
  assert (r.container.id = None && r.container.state = None);
  assert (r.container.podman_state = None && r.container.created = None);
  assert (r.container.owned = None && r.container.compatible = None);
  let run, _ = fake ~image_result:missing missing in
  let r = collect run in
  assert (r.image.exists = Some false && r.container.exists = Some false);
  (* Foreign labels: not owned, so compatibility is not evaluated. *)
  let run, _ = fake (ok (container ~project:"other" ~init:false "running")) in
  let r = collect run in
  assert (r.container.owned = Some false && r.image.owned = Some true);
  assert (r.container.compatible = None && r.container.incompatibilities = []);
  let run, _ =
    fake
      ~image_result:(ok (image ~project:"other" ()))
      (ok (container "running"))
  in
  let r = collect run in
  assert (r.image.owned = Some false && r.container.owned = Some true);
  assert (r.container.compatible = None);
  (* Every mismatch is listed. *)
  let run, _ =
    fake (ok (container ~init:false ~image:"other" ~workdir:"/tmp" "exited"))
  in
  let r = collect run in
  assert (r.container.compatible = Some false);
  assert (
    r.container.incompatibilities
    = [
        "Container image differs";
        "Container init is disabled";
        "Working directory differs";
      ]);
  (* State mapping. *)
  List.iter
    (fun (podman, simple) ->
      assert (Info.state_of_podman podman = simple);
      let run, _ = fake (ok (container podman)) in
      let r = collect run in
      assert (r.container.state = Some simple);
      assert (r.container.podman_state = Some podman))
    [
      ("running", "running");
      ("created", "stopped");
      ("configured", "stopped");
      ("exited", "stopped");
      ("stopped", "stopped");
      ("paused", "paused");
      ("removing", "unknown");
      ("dead", "unknown");
    ];
  (* Missing or unparseable creation times are null. *)
  List.iter
    (fun created ->
      let run, _ =
        fake
          ~image_result:(ok (image ~created ()))
          (ok (container ~created "running"))
      in
      let r = collect run in
      assert (r.image.created = None && r.container.created = None))
    [ `Null; `String "yesterday" ];
  (* Configured workdir wins over the image's; an empty image workdir is
     unknown. *)
  let run, _ = fake ~image_result:missing missing in
  let r =
    collect
      ~loaded:
        (load "[project]\nname = 'example'\n[container]\nworkdir = '/srv'\n")
      run
  in
  assert (r.runtime.workdir = Some "/srv" && r.project.description = None);
  let run, _ =
    fake
      ~image_result:(ok (image ~workdir:"" ()))
      (ok (container ~workdir:"" "running"))
  in
  assert ((collect run).runtime.workdir = None);
  (* Keep-id user mode. *)
  let keep =
    {
      loaded with
      identity =
        User_identity.Keep_id
          {
            name = "dev";
            host = { uid = 1000; gid = 1000 };
            container = { uid = 1000; gid = 1000 };
          };
    }
  in
  let run, _ = fake ~image_result:missing missing in
  assert ((collect ~loaded:keep run).runtime.user_mode = "keep-id");
  (* The workspace mount with each relabel policy. *)
  List.iter
    (fun (toml, relabel) ->
      let base =
        load
          ("[project]\nname = 'example'\n[mounts.workspace]\nsource = '.'\n"
         ^ "target = '/workspace'\nrelabel = '" ^ toml ^ "'\n")
      in
      let with_source =
        {
          base with
          host_paths =
            { base.host_paths with workspace_source = Some "/project" };
        }
      in
      let run, _ = fake ~image_result:missing missing in
      let r = collect ~loaded:with_source run in
      assert (
        r.mounts
        = [
            {
              source = "/project";
              target = "/workspace";
              kind = "bind";
              readonly = false;
              relabel;
            };
          ]);
      let json = Info.render_json r in
      assert (contains json {|"type": "bind"|});
      assert (contains json {|"readonly": false|});
      assert (contains json ({|"relabel": "|} ^ relabel ^ {|"|})))
    [ ("shared", "shared"); ("private", "private"); ("none", "none") ];
  (* SELinux is detected only when it decides a relabel mismatch. *)
  let mounted =
    let base =
      load
        "[project]\n\
         name = 'example'\n\
         [mounts.workspace]\n\
         source = '.'\n\
         target = '/workspace'\n\
         relabel = 'private'\n"
    in
    {
      base with
      host_paths = { base.host_paths with workspace_source = Some "/project" };
    }
  in
  let bind =
    `Assoc
      [
        ("Type", `String "bind");
        ("Source", `String "/project");
        ("Destination", `String "/workspace");
        ("Options", `List [ `String "rbind" ]);
      ]
  in
  List.iter
    (fun (enabled, compatible) ->
      let probed = ref 0 in
      let probe () =
        incr probed;
        Some enabled
      in
      let run, _ =
        fake (ok (container ~workdir:"/workspace" ~mounts:[ bind ] "running"))
      in
      let r = collect ~loaded:mounted ~probe run in
      assert (!probed = 1);
      assert (r.container.compatible = Some compatible))
    [ (true, false); (false, true) ];
  let probed = ref false in
  let run, _ = fake (ok (container "running")) in
  ignore
    (collect
       ~probe:(fun () ->
         probed := true;
         None)
       run);
  assert (not !probed);
  (* Podman unavailable: a full report with unknown Podman fields. *)
  List.iter
    (fun version ->
      let run, calls = fake ~version (ok (container "running")) in
      match Info.collect ~run ~probe:no_probe ~trust:None loaded with
      | Ok (r, Some reason) ->
          assert (reason <> "");
          assert (!calls = [ version_json ]);
          assert (r.podman = { available = false; version = None });
          assert (r.project.name = "example");
          assert (r.image.name = "example-dev-image");
          assert (r.image.id = None && r.image.exists = None);
          assert (r.image.owned = None && r.image.created = None);
          assert (r.container.exists = None && r.container.state = None);
          assert (r.container.compatible = None);
          assert (r.runtime.workdir = None);
          let json = Info.render_json r in
          assert (contains json {|"trust": null,|});
          assert (contains json {|"available": false, "version": null|});
          assert (contains json {|"exists": null|})
      | _ -> assert false)
    [
      Error { Process.operation = "launch"; message = "not found" };
      ok ~status:(Unix.WEXITED 125) "";
    ];
  (* A failed query that leaves Podman usable is an error. *)
  let failing =
    Ok { Process.status = Unix.WSIGNALED 9; stdout = ""; stderr = "" }
  in
  let run, _ = fake failing in
  (match Info.collect ~run ~probe:no_probe ~trust:None loaded with
  | Error (Podman.Runtime _) -> ()
  | _ -> assert false);
  (* ... unless Podman has become unavailable in the meantime. *)
  let run, _ = fake ~probe_version:(ok ~status:(Unix.WEXITED 125) "") failing in
  (match Info.collect ~run ~probe:no_probe ~trust:None loaded with
  | Ok (r, Some _) -> assert (not r.podman.available)
  | _ -> assert false);
  (* Malformed responses are errors. *)
  let run, _ = fake (ok "not json") in
  (match Info.collect ~run ~probe:no_probe ~trust:None loaded with
  | Error (Podman.Invalid_response _) -> ()
  | _ -> assert false);
  let run, _ = fake ~version:(ok "{}") (ok (container "running")) in
  match Info.collect ~run ~probe:no_probe ~trust:None loaded with
  | Error (Podman.Invalid_response _) -> ()
  | _ -> assert false
