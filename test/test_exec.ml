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
  let labels =
    `Assoc
      [
        ("dev.deco.managed", `String "true");
        ("dev.deco.project", `String "example");
        ("dev.deco.project-root", `String "/project");
      ]
  in
  let json state =
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
    (fun state ->
      List.iter
        (fun status ->
          let started = ref false and executed = ref false in
          let execute output argv =
            let stdout =
              match argv with
              | [ "podman"; "--remote=false"; "version" ] -> "{}"
              | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] ->
                  image
              | [
               "podman"; "--remote=false"; "container"; "inspect"; "--"; target;
              ] ->
                  if !started then assert (target = "cid");
                  json (if !started then "running" else state)
              | [ "podman"; "--remote=false"; "start"; "--"; "cid" ] ->
                  assert (output = Process.Capture);
                  started := true;
                  ""
              | [
               "podman";
               "--remote=false";
               "exec";
               "--interactive";
               "--";
               "cid";
               "true";
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
              | _ -> failwith "Unexpected command"
            in
            Ok
              {
                Process.status = (if !executed then status else Unix.WEXITED 0);
                stdout;
                stderr = "";
              }
          in
          let outcome =
            Result.get_ok (Exec.run ~execute loaded ~tty:false [ "true" ])
          in
          assert (!executed && outcome.status = status);
          assert (outcome.started = (state <> "running")))
        [ Unix.WEXITED 0; Unix.WEXITED 17; Unix.WSIGNALED Sys.sigterm ])
    [ "running"; "created"; "configured"; "exited"; "stopped" ];
  let execute _ _ = failwith "Invalid plan invoked runner" in
  assert (Result.is_error (Exec.run ~execute loaded ~tty:false []))
