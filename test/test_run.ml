open Deco

let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "[project]\n\
          name = 'example'\n\
          [hooks]\n\
          post_start = 'echo ready'\n\
          [actions]\n\
          test = 'make test'\n")
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
  let labels =
    `Assoc
      [
        ("dev.deco.managed", `String "true");
        ("dev.deco.project", `String "example");
        ("dev.deco.project-root", `String "/project");
      ]
  in
  let container state =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String "cid");
               ("Image", `String "iid");
               ("State", `Assoc [ ("Status", `String state) ]);
               ( "Config",
                 `Assoc [ ("Labels", labels); ("WorkingDir", `String "/") ] );
               ( "HostConfig",
                 `Assoc [ ("UsernsMode", `String ""); ("Init", `Bool true) ] );
               ("Mounts", `List []);
             ];
         ])
  in
  let image =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String "iid");
               ("Labels", labels);
               ("Config", `Assoc [ ("WorkingDir", `String "/") ]);
             ];
         ])
  in
  List.iter
    (fun (state, status) ->
      let started = ref false and executed = ref false and hooks = ref [] in
      let execute output argv =
        let stdout =
          match argv with
          | [ "podman"; "--remote=false"; "version" ] -> "{}"
          | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] -> image
          | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] ->
              container (if !started then "running" else state)
          | [ "podman"; "--remote=false"; "start"; "--"; "cid" ] ->
              started := true;
              ""
          | [
           "podman";
           "--remote=false";
           "exec";
           "--interactive";
           "--";
           "cid";
           "sh";
           "-lc";
           "make test";
          ] ->
              assert (output = Process.Inherit);
              executed := true;
              ""
          | [
           "podman";
           "--remote=false";
           ("image" | "container");
           "exists";
           "--";
           _;
          ] ->
              ""
          | _ -> failwith ("Unexpected command: " ^ String.concat " " argv)
        in
        Ok
          {
            Process.status = (if !executed then status else Unix.WEXITED 0);
            stdout;
            stderr = "";
          }
      in
      let hook argv =
        assert (not !executed);
        hooks := argv :: !hooks;
        Ok { Process.status = Unix.WEXITED 0; stdout = ""; stderr = "" }
      in
      match Run.run ~execute ~hook loaded ~tty:false "test" with
      | Ok outcome ->
          (* The action's status passes through; a stopped container is
             started and post_start runs before the action. *)
          assert (!executed && outcome.status = status);
          assert (outcome.started = (state <> "running"));
          assert (List.length !hooks = if state = "running" then 0 else 1)
      | Error _ -> assert false)
    [
      ("running", Unix.WEXITED 0);
      ("running", Unix.WEXITED 3);
      ("exited", Unix.WEXITED 0);
      ("exited", Unix.WSIGNALED Sys.sigterm);
    ];
  (* An unknown action invokes no runner. *)
  let execute _ _ = failwith "Unknown action invoked a runner" in
  assert (
    Run.run ~execute loaded ~tty:false "nope"
    = Error (Run.Unknown_action "nope"))
