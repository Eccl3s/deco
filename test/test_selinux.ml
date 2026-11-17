open Deco

let get = function Ok x -> x | Error e -> failwith e

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname = 'example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
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
  let loaded =
    {
      loaded with
      effective =
        {
          loaded.effective with
          mounts =
            {
              workspace =
                Some
                  {
                    source = ".";
                    target = "/workspace";
                    relabel = Config.Private;
                  };
            };
        };
      host_paths = { loaded.host_paths with workspace_source = Some "/project" };
    }
  in
  List.iter
    (fun (options, detected, expected_probes, expected_info, success) ->
      let probes = ref 0 and infos = ref 0 and started = ref false in
      let probe () =
        incr probes;
        detected
      in
      let execute _ argv =
        let stdout =
          match argv with
          | [ "podman"; "--remote=false"; "version" ] -> ""
          | [ "podman"; "--remote=false"; "info"; "--format"; "json" ] ->
              incr infos;
              "{\"host\":{\"security\":{\"selinuxEnabled\":false}}}"
          | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] -> image
          | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] -> (
              let raw =
                Yojson.Basic.from_string
                  (json (if !started then "running" else "exited"))
              in
              match raw with
              | `List [ `Assoc fields ] ->
                  Yojson.Basic.to_string
                    (`List
                       [
                         `Assoc
                           (( "Mounts",
                              `List
                                [
                                  `Assoc
                                    [
                                      ("Type", `String "bind");
                                      ("Source", `String "/project");
                                      ("Destination", `String "/workspace");
                                      ( "Options",
                                        `List
                                          (List.map
                                             (fun x -> `String x)
                                             options) );
                                    ];
                                ] )
                           :: List.remove_assoc "Mounts" fields);
                       ])
              | _ -> assert false)
          | [ "podman"; "--remote=false"; "start"; "--"; "cid" ] ->
              started := true;
              ""
          | "podman" :: "--remote=false" :: "exec" :: _ -> ""
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
        Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" }
      in
      let result =
        Exec.run ~execute
          ~read_many:(List.map (execute Process.Capture))
          ~probe loaded ~tty:false [ "true" ]
      in
      assert (Result.is_ok result = success);
      assert (!probes = expected_probes && !infos = expected_info);
      probes := 0;
      infos := 0;
      started := false;
      let assembled =
        Assemble.run ~execute
          ~read_many:(List.map (execute Process.Capture))
          ~probe loaded
      in
      assert (Result.is_ok assembled = success);
      assert (!probes = expected_probes && !infos = expected_info))
    [
      ([ "Z" ], Some true, 0, 0, true);
      ([], Some false, 1, 0, true);
      ([], Some true, 1, 0, false);
      ([], None, 1, 1, true);
      ([ "z" ], Some false, 0, 0, false);
    ]
