open Deco

let get = function Ok x -> x | Error e -> failwith e

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname = 'example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
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
  let response ?(status = Unix.WEXITED 0) stdout =
    Ok { Process.status; stdout; stderr = "" }
  in
  let labels =
    [
      ("dev.deco.managed", `String "true");
      ("dev.deco.project", `String "example");
      ("dev.deco.project-root", `String "/project");
    ]
  in
  let container ?(id = "cid") ?(labels = labels) state =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String id);
               ("Image", `String "missing-image");
               ("State", `Assoc [ ("Status", `String state) ]);
               ("Config", `Assoc [ ("Labels", `Assoc labels) ]);
               ("HostConfig", `Assoc [ ("UsernsMode", `String "") ]);
               ("Mounts", `List []);
             ];
         ])
  in
  let inspect target = Podman_command.inspect "container" target in
  let initial = inspect "example-dev-container" in
  let version = (Podman_command.version, response "") in
  let run script =
    let remaining = ref script in
    let result =
      Stop.run
        ~run:(fun argv ->
          match !remaining with
          | (expected, result) :: rest ->
              assert (argv = expected);
              remaining := rest;
              result
          | [] -> failwith "Unexpected operation")
        loaded
    in
    assert (!remaining = []);
    result
  in
  let error completed result =
    match result with
    | Error e ->
        assert (e.Stop.stop_completed = completed);
        e.cause
    | Ok _ -> failwith "Expected failure"
  in
  List.iter
    (fun state ->
      let outcome =
        Result.get_ok (run [ version; (initial, response (container state)) ])
      in
      assert (outcome.container_id = "cid" && not outcome.stopped))
    [ "created"; "configured"; "exited"; "stopped" ];
  let prefix = [ version; (initial, response (container "running")) ] in
  let stopped = prefix @ [ (Podman_command.stop "cid", response "") ] in
  let outcome =
    Result.get_ok
      (run (stopped @ [ (inspect "cid", response (container "exited")) ]))
  in
  assert (outcome.stopped && outcome.container_id = "cid");
  List.iter
    (fun state ->
      match
        error false (run [ version; (initial, response (container state)) ])
      with
      | Stop.Conflict _ -> ()
      | _ -> assert false)
    [ "paused"; "removing"; "unknown" ];
  List.iter
    (fun labels ->
      match
        error false
          (run [ version; (initial, response (container ~labels "running")) ])
      with
      | Stop.Conflict _ -> ()
      | _ -> assert false)
    [
      [];
      ("dev.deco.managed", `String "true") :: labels;
      List.remove_assoc "dev.deco.project" labels;
    ];
  let absent target =
    [
      (inspect target, response ~status:(Unix.WEXITED 125) "");
      ( Podman_command.exists "container" target,
        response ~status:(Unix.WEXITED 1) "" );
    ]
  in
  (match error false (run (version :: absent "example-dev-container")) with
  | Stop.Conflict _ -> ()
  | _ -> assert false);
  List.iter
    (fun result ->
      match
        error false (run (prefix @ [ (Podman_command.stop "cid", result) ]))
      with
      | Stop.Runtime _ -> ()
      | _ -> assert false)
    [
      response ~status:(Unix.WEXITED 125) "";
      response ~status:(Unix.WSIGNALED Sys.sigterm) "";
      Error { Process.operation = "launch"; message = "failed" };
    ];
  List.iter
    (fun tail -> ignore (error true (run (stopped @ tail))))
    [
      absent "cid";
      [ (inspect "cid", response (container ~id:"other" "exited")) ];
      [ (inspect "cid", response (container ~labels:[] "exited")) ];
      [ (inspect "cid", response (container "running")) ];
      [ (inspect "cid", response "bad") ];
    ];
  (match
     error false
       (run
          [ (Podman_command.version, response ~status:(Unix.WEXITED 125) "") ])
   with
  | Stop.Podman (Podman.Unavailable _) -> ()
  | _ -> assert false);
  List.iter
    (fun info_result ->
      match
        error false
          (run
             [
               version;
               (initial, response ~status:(Unix.WEXITED 125) "inspection failed");
               ( Podman_command.exists "container" "example-dev-container",
                 response "" );
               (Podman_command.info, info_result);
             ])
      with
      | Stop.Podman _ -> ()
      | _ -> assert false)
    [ response "{}"; response ~status:(Unix.WEXITED 125) "unavailable" ];
  ignore (error false (run [ version; (initial, response "bad") ]));
  ignore
    (error true
       (run (stopped @ [ (inspect "cid", response (container "paused")) ])));
  ignore
    (error true
       (run
          (stopped
          @ [
              ( inspect "cid",
                Error { Process.operation = "launch"; message = "failed" } );
              ( Podman_command.info,
                response ~status:(Unix.WEXITED 125) "unavailable" );
            ])));
  let invalid =
    {
      loaded with
      effective =
        {
          loaded.effective with
          container = { loaded.effective.container with name = "bad\000name" };
        };
    }
  in
  assert (
    Result.is_error
      (Stop.run ~run:(fun _ -> failwith "Invalid plan touched runtime") invalid))
