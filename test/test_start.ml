open Deco

let contains s fragment =
  let rec loop i =
    i + String.length fragment <= String.length s
    && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname = 'example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
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
  in
  let labels project =
    `Assoc
      [
        ("dev.deco.managed", `String "true");
        ("dev.deco.project", `String project);
        ("dev.deco.project-root", `String "/project");
      ]
  in
  let container ?(id = "cid") ?(image = "iid") ?(project = "example")
      ?(init = true) state =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String id);
               ("Image", `String image);
               ("State", `Assoc [ ("Status", `String state) ]);
               ( "Config",
                 `Assoc
                   [ ("Labels", labels project); ("WorkingDir", `String "/") ]
               );
               ( "HostConfig",
                 `Assoc [ ("UsernsMode", `String ""); ("Init", `Bool init) ] );
               ("Mounts", `List []);
             ];
         ])
  in
  let image ?(id = "iid") () =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String id);
               ("Labels", labels "example");
               ("Config", `Assoc [ ("WorkingDir", `String "/") ]);
             ];
         ])
  in
  let ok ?(status = Unix.WEXITED 0) stdout =
    Ok { Process.status; stdout; stderr = "" }
  in
  let version = Podman_command.version in
  let image_inspect =
    Podman_command.inspect "image" "example-dev-image:latest"
  in
  let container_inspect target = Podman_command.inspect "container" target in
  let start = Podman_command.start "cid" in
  (* A fake Podman. [before] and [after] give the container inspection before
     and after a start; [start_result] answers the start itself. All calls
     are recorded. *)
  let fake ?(version_result = ok "") ?(image_result = ok (image ()))
      ?(start_result = ok "") ?after before =
    let calls = ref [] and started = ref false in
    let run argv =
      calls := argv :: !calls;
      if argv = version then version_result
      else if argv = image_inspect then image_result
      else if argv = Podman_command.exists "image" "example-dev-image:latest"
      then ok ~status:(Unix.WEXITED 1) ""
      else if argv = container_inspect "example-dev-container" then (
        assert (not !started);
        before)
      else if argv = Podman_command.exists "container" "example-dev-container"
      then ok ~status:(Unix.WEXITED 1) ""
      else if argv = start then (
        started := true;
        start_result)
      else if argv = container_inspect "cid" then (
        assert !started;
        Option.get after)
      else failwith ("Unexpected command: " ^ String.concat " " argv)
    in
    (run, calls)
  in
  let conflict ?(started = false) fragment = function
    | Error { Start.cause = Start.Conflict message; started = s } ->
        assert (s = started);
        if not (contains message fragment) then failwith message
    | _ -> assert false
  in
  let runtime ~started fragment = function
    | Error { Start.cause = Start.Runtime message; started = s } ->
        assert (s = started);
        if not (contains message fragment) then failwith message
    | _ -> assert false
  in
  (* An already running container is verified but not started. *)
  let run, calls = fake (ok (container "running")) in
  (match Start.run ~run loaded with
  | Ok { started = false; environment } ->
      assert (environment.container.id = "cid");
      assert (environment.image.id = "iid")
  | _ -> assert false);
  assert (not (List.mem start !calls));
  (* Stopped supported states are started by ID and verified running. *)
  List.iter
    (fun state ->
      let run, calls =
        fake ~after:(ok (container "running")) (ok (container state))
      in
      (match Start.run ~run loaded with
      | Ok { started = true; environment } ->
          assert (environment.container.state = "running")
      | _ -> assert false);
      assert (List.mem start !calls))
    [ "created"; "configured"; "exited"; "stopped" ];
  (* Reads are batched when read_many is supplied, both initially and when
     reinspecting the started container by ID. *)
  let run, _ =
    fake ~after:(ok (container "running")) (ok (container "exited"))
  in
  let batches = ref [] in
  let read_many commands =
    batches := commands :: !batches;
    List.map run commands
  in
  (match Start.run ~run ~read_many loaded with
  | Ok { started = true; _ } -> ()
  | _ -> assert false);
  assert (
    List.rev !batches
    = [
        [ version; image_inspect; container_inspect "example-dev-container" ];
        [ version; image_inspect; container_inspect "cid" ];
      ]);
  (* Missing, unowned, incompatible, or unsupported resources are refused
     without a start. *)
  List.iter
    (fun (run, fragment) ->
      let run, calls = run in
      conflict fragment (Start.run ~run loaded);
      assert (not (List.mem start !calls)))
    [
      (fake (ok ~status:(Unix.WEXITED 125) ""), "run deco assemble");
      ( fake
          ~image_result:(ok ~status:(Unix.WEXITED 125) "")
          (ok (container "exited")),
        "Configured image is missing; run deco assemble" );
      ( fake (ok (container ~project:"other" "exited")),
        "container example-dev-container belongs to Deco project \"other\"" );
      (fake (ok (container ~init:false "exited")), "Container init is disabled");
      (fake (ok (container "paused")), "Unsupported container state");
    ];
  (* Podman unavailable: nothing else runs. *)
  let run, calls =
    fake
      ~version_result:
        (Error
           {
             Process.operation = "launch";
             message = "podman: command not found";
           })
      (ok (container "exited"))
  in
  (match Start.run ~run loaded with
  | Error { cause = Start.Podman (Podman.Unavailable _); started = false } -> ()
  | _ -> assert false);
  assert (!calls = [ version ]);
  (* A failed start is a runtime failure with nothing started. *)
  let run, _ =
    fake
      ~start_result:
        (Ok { Process.status = Unix.WEXITED 125; stdout = ""; stderr = "boom" })
      (ok (container "exited"))
  in
  runtime ~started:false "boom" (Start.run ~run loaded);
  let run, _ =
    fake
      ~start_result:(Error { Process.operation = "launch"; message = "gone" })
      (ok (container "exited"))
  in
  runtime ~started:false "gone" (Start.run ~run loaded);
  (* After a successful start, verification failures keep started = true. *)
  let run, _ =
    fake ~after:(ok (container "exited")) (ok (container "exited"))
  in
  runtime ~started:true "not running after start" (Start.run ~run loaded);
  let run, _ =
    fake ~after:(ok (container ~id:"other" "running")) (ok (container "exited"))
  in
  conflict ~started:true "Resource ID changed" (Start.run ~run loaded);
  let run, _ =
    fake
      ~after:(ok (container ~image:"iid2" "running"))
      ~image_result:(ok (image ()))
      (ok (container "exited"))
  in
  (match Start.run ~run loaded with
  | Error { cause = Start.Conflict _; started = true } -> ()
  | _ -> assert false);
  (* post_start runs once in the verified started container, after the
     reinspection; an already running container runs no hook. *)
  let hooked =
    {
      loaded with
      effective =
        {
          effective with
          hooks = { effective.hooks with post_start = Some "echo ready" };
        };
    }
  in
  let hook_calls = ref [] in
  let hook ?(status = Unix.WEXITED 0) calls argv =
    hook_calls := (argv, List.length !calls) :: !hook_calls;
    Ok { Process.status; stdout = ""; stderr = "" }
  in
  let post_start =
    [
      "podman"; "--remote=false"; "exec"; "--"; "cid"; "sh"; "-lc"; "echo ready";
    ]
  in
  let run, calls =
    fake ~after:(ok (container "running")) (ok (container "exited"))
  in
  (match Start.run ~run ~hook:(hook calls) hooked with
  | Ok { started = true; _ } -> ()
  | _ -> assert false);
  (* Every Podman call, including the reinspection, came first. *)
  assert (!hook_calls = [ (post_start, List.length !calls) ]);
  assert (List.hd !calls = container_inspect "cid");
  hook_calls := [];
  let run, calls = fake (ok (container "running")) in
  (match Start.run ~run ~hook:(hook calls) hooked with
  | Ok { started = false; _ } -> ()
  | _ -> assert false);
  assert (!hook_calls = []);
  (* A failed hook leaves the container running and keeps its status. *)
  let run, calls =
    fake ~after:(ok (container "running")) (ok (container "exited"))
  in
  (match Start.run ~run ~hook:(hook ~status:(Unix.WEXITED 7) calls) hooked with
  | Error
      {
        cause =
          Start.Hook (Hook.Exited { hook = Post_start; status = WEXITED 7 });
        started = true;
      } ->
      ()
  | _ -> assert false);
  assert (not (List.mem (Podman_command.stop "cid") !calls));
  (* A failed verification runs no hook. *)
  hook_calls := [];
  let run, calls =
    fake ~after:(ok (container "exited")) (ok (container "exited"))
  in
  runtime ~started:true "not running after start"
    (Start.run ~run ~hook:(hook calls) hooked);
  assert (!hook_calls = []);
  (* A container that was never started still owes post_create, which runs
     before post_start; a stopped container that ran before runs only
     post_start. *)
  let both =
    {
      hooked with
      effective =
        {
          hooked.effective with
          hooks = { hooked.effective.hooks with post_create = Some "setup" };
        };
    }
  in
  List.iter
    (fun (state, expected) ->
      hook_calls := [];
      let run, calls =
        fake ~after:(ok (container "running")) (ok (container state))
      in
      (match Start.run ~run ~hook:(hook calls) both with
      | Ok { started = true; _ } -> ()
      | _ -> assert false);
      assert (
        List.rev_map (fun (argv, _) -> List.hd (List.rev argv)) !hook_calls
        = expected))
    [
      ("created", [ "setup"; "echo ready" ]);
      ("configured", [ "setup"; "echo ready" ]);
      ("exited", [ "echo ready" ]);
      ("stopped", [ "echo ready" ]);
    ];
  (* Invalid plans fail before Podman is invoked. *)
  let invalid =
    {
      loaded with
      effective =
        {
          effective with
          container = { effective.container with name = "bad\000name" };
        };
    }
  in
  let run _ = failwith "Podman must not run" in
  match Start.run ~run invalid with
  | Error { cause = Start.Planning _; started = false } -> ()
  | _ -> assert false
