open Deco

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname='example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      source;
      effective;
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
        };
      identity = Image;
    }
  in
  let labels =
    [
      ("dev.deco.managed", "true");
      ("dev.deco.project", "example");
      ("dev.deco.project-root", "/project");
    ]
  in
  let image : Podman.image =
    { id = "iid"; labels; user = ""; workdir = "/"; created = None }
  in
  let c : Podman.container =
    {
      id = "cid";
      labels;
      state = "running";
      image_id = "iid";
      user = "";
      userns = "";
      workdir = "/";
      init = true;
      mounts = [];
      created = None;
    }
  in
  assert (Assemble.compatibility loaded image c = Ok ());
  assert (Container_runtime.incompatibilities loaded image c = []);
  (* Every mismatch is reported, in a fixed order, and compatibility joins
     them. *)
  let broken = { c with image_id = "other"; init = false; workdir = "/tmp" } in
  let expected =
    [
      "Container image differs";
      "Container init is disabled";
      "Working directory differs";
    ]
  in
  assert (Container_runtime.incompatibilities loaded image broken = expected);
  assert (
    Assemble.compatibility loaded image broken
    = Error (String.concat "; " expected));
  let mounted =
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
  let mounted_c =
    {
      c with
      mounts =
        [
          {
            Podman.kind = "bind";
            source = "/project";
            destination = "/workspace";
            options = [ "rbind" ];
          };
        ];
    }
  in
  assert (
    Assemble.compatibility ~selinux_enabled:false mounted image mounted_c
    = Ok ());
  assert (
    Result.is_error
      (Assemble.compatibility ~selinux_enabled:true mounted image mounted_c));
  assert (Result.is_error (Assemble.compatibility mounted image mounted_c));
  assert (
    Result.is_error
      (Assemble.compatibility ~selinux_enabled:false mounted image
         {
           mounted_c with
           mounts = [ { (List.hd mounted_c.mounts) with options = [ "z" ] } ];
         }));

  List.iter
    (fun c -> assert (Result.is_error (Assemble.compatibility loaded image c)))
    [
      { c with init = false };
      { c with image_id = "other" };
      { c with workdir = "/bad" };
      { c with user = "dev" };
    ];
  let calls = ref [] in
  let execute output argv =
    calls := (output, argv) :: !calls;
    let stdout =
      match argv with
      | [ "podman"; "--remote=false"; "version" ] -> ""
      | [ "podman"; "--remote=false"; _; "exists"; "--"; _ ] -> ""
      | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] ->
          {|[{"Id":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":"/project"},"Config":{"User":"","WorkingDir":"/"}}]|}
      | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] ->
          {|[{"Id":"cid","Image":"iid","Config":{"Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":"/project"},"User":"","WorkingDir":"/"},"HostConfig":{"Init":true,"UsernsMode":""},"State":{"Status":"running"},"Mounts":[]}]|}
      | _ -> failwith "Unexpected mutation"
    in
    Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" }
  in
  assert (
    Assemble.run ~execute loaded
    = Ok
        {
          Assemble.image_id = "iid";
          container_id = "cid";
          created = false;
          started = false;
        });
  assert (List.length !calls = 3);
  let error =
    Assemble.run
      ~execute:(fun _ _ ->
        Error { Process.operation = "launch"; message = "missing" })
      loaded
  in
  assert (
    match error with
    | Error { cause = Podman (Unavailable _); completed = [] } -> true
    | _ -> false);

  let stopped = ref true in
  let restart output argv =
    match argv with
    | [ "podman"; "--remote=false"; "start"; "--"; "cid" ] ->
        stopped := false;
        Ok { Process.status = Unix.WEXITED 0; stdout = "cid"; stderr = "" }
    | _ -> (
        match execute output argv with
        | Ok r
          when !stopped && List.mem "container" argv && List.mem "inspect" argv
          ->
            let json = Yojson.Basic.from_string r.stdout in
            let json =
              match json with
              | `List [ `Assoc fields ] ->
                  `List
                    [
                      `Assoc
                        (("State", `Assoc [ ("Status", `String "exited") ])
                        :: List.remove_assoc "State" fields);
                    ]
              | _ -> assert false
            in
            Ok { r with stdout = Yojson.Basic.to_string json }
        | r -> r)
  in
  assert (
    match Assemble.run ~execute:restart loaded with
    | Ok o -> o.started && not o.created
    | _ -> false);
  let fail_start output argv =
    match argv with
    | [ "podman"; "--remote=false"; "start"; "--"; "cid" ] ->
        Ok
          {
            Process.status = Unix.WSIGNALED Sys.sigterm;
            stdout = "";
            stderr = "interrupted";
          }
    | _ -> restart output argv
  in
  stopped := true;
  assert (
    match Assemble.run ~execute:fail_start loaded with
    | Error { cause = Runtime _; completed = [] } -> true
    | _ -> false)

(* Scripted scenarios assert every command, output mode, and early stop. *)
let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname='example'\n")
  in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
        };
      identity = Image;
    }
  in
  let plan = Result.get_ok (Assemble_plan.make loaded) in
  let id = String.make 64 'a' in
  let labels =
    `Assoc
      [
        ("dev.deco.managed", `String "true");
        ("dev.deco.project", `String "example");
        ("dev.deco.project-root", `String "/project");
      ]
  in
  let image ?(labels = labels) () =
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
  let container ?(state = "created") ?(image_id = "iid") ?(labels = labels) () =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String id);
               ("Image", `String image_id);
               ( "Config",
                 `Assoc
                   [
                     ("Labels", labels);
                     ("User", `String "");
                     ("WorkingDir", `String "/");
                   ] );
               ( "HostConfig",
                 `Assoc [ ("Init", `Bool true); ("UsernsMode", `String "host") ]
               );
               ("State", `Assoc [ ("Status", `String state) ]);
               ("Mounts", `List []);
             ];
         ])
  in
  let response ?(code = 0) stdout =
    Ok { Process.status = Unix.WEXITED code; stdout; stderr = "" }
  in
  let read args r = (Process.Capture, args, r) in
  let info = read Podman_command.version (response "") in
  let ie r =
    read (Podman_command.exists "image" "example-dev-image:latest") r
  in
  let ii ?(labels = labels) () =
    read
      (Podman_command.inspect "image" "example-dev-image:latest")
      (response (image ~labels ()))
  in
  let ce r =
    read (Podman_command.exists "container" "example-dev-container") r
  in
  let ci ?(state = "created") ?(image_id = "iid") ?(labels = labels) () =
    read
      (Podman_command.inspect "container" "example-dev-container")
      (response (container ~state ~image_id ~labels ()))
  in
  let build r = (Process.Inherit, plan.build, r) in
  let create r =
    read (Assemble_plan.resolve ~image_id:"iid" ~container_id:"" plan.create) r
  in
  let post state =
    [
      read (Podman_command.exists "container" id) (response "");
      read
        (Podman_command.inspect "container" id)
        (response (container ~state ()));
    ]
  in
  let start r = read [ "podman"; "--remote=false"; "start"; "--"; id ] r in
  let run script =
    (* Expand resource-presence fixtures into the inspect-first protocol. *)
    let rec inspection_script = function
      | ((mode, [ p; flag; kind; "exists"; sep; name ], _) as original) :: rest
        -> (
          let command = [ p; flag; kind; "inspect"; sep; name ] in
          match rest with
          | (next_mode, expected, _) :: tail when expected = command ->
              ( next_mode,
                expected,
                let _, _, r = List.hd rest in
                r )
              :: inspection_script tail
          | _ ->
              (mode, command, response ~code:125 "")
              :: original :: inspection_script rest)
      | item :: rest -> item :: inspection_script rest
      | [] -> []
    in
    let script = inspection_script script in
    let pending = ref script in
    let execute output argv =
      match !pending with
      | (mode, expected, r) :: rest ->
          assert (mode = output);
          assert (argv = expected);
          pending := rest;
          r
      | [] -> failwith ("Unexpected command: " ^ String.concat " " argv)
    in
    let result = Assemble.run ~execute loaded in
    assert (!pending = []);
    result
  in
  let missing = [ info; ie (response ~code:1 ""); ce (response ~code:1 "") ] in
  let built = missing @ [ build (response ""); ie (response ""); ii () ] in
  let existing = [ info; ie (response ""); ii (); ce (response ~code:1 "") ] in
  assert (
    match
      run
        (built
        @ [ create (response (id ^ "\n")) ]
        @ post "created"
        @ [ start (response id) ]
        @ post "running")
    with
    | Ok o ->
        o.created && o.started && o.image_id = "iid" && o.container_id = id
    | _ -> false);
  assert (
    match
      run
        (existing
        @ [ create (response id) ]
        @ post "created"
        @ [ start (response id) ]
        @ post "running")
    with
    | Ok o -> o.created && o.started
    | _ -> false);
  let conflict script =
    assert (
      match run script with
      | Error { cause = Conflict _; completed = [] } -> true
      | _ -> false)
  in
  conflict [ info; ie (response ""); ii ~labels:(`Assoc []) () ];
  conflict
    [
      info; ie (response ""); ii (); ce (response ""); ci ~labels:(`Assoc []) ();
    ];
  conflict
    [ info; ie (response ""); ii (); ce (response ""); ci ~image_id:"other" () ];
  conflict
    [ info; ie (response ""); ii (); ce (response ""); ci ~state:"paused" () ];
  conflict [ info; ie (response ~code:1 ""); ce (response ""); ci () ];
  (* Ownership refusals: the script ends at the failing inspection, so any
     build, create or start would be an unexpected command. A moved project
     and another project with the same name both differ only in the root. *)
  let owned_by ?(managed = "true") ?(project = "example") root =
    `Assoc
      [
        ("dev.deco.managed", `String managed);
        ("dev.deco.project", `String project);
        ("dev.deco.project-root", `String root);
      ]
  in
  List.iter
    (fun labels ->
      conflict [ info; ie (response ""); ii ~labels () ];
      conflict
        [ info; ie (response ""); ii (); ce (response ""); ci ~labels () ])
    [
      owned_by "/old/project";
      owned_by ~project:"other" "/other";
      owned_by ~managed:"false" "/project";
    ];
  List.iter
    (fun bad ->
      assert (
        match run (existing @ [ create (response bad) ]) with
        | Error
            {
              cause = Runtime _;
              completed = [ "podman --remote=false create" ];
            } ->
            true
        | _ -> false))
    [ ""; "short"; String.make 64 'z' ];
  assert (
    match run (missing @ [ build (response ~code:125 "") ]) with
    | Error { cause = Runtime _; completed = [] } -> true
    | _ -> false);
  assert (
    match run (built @ [ create (response ~code:125 "") ]) with
    | Error { cause = Runtime _; completed = [ "podman --remote=false build" ] }
      ->
        true
    | _ -> false);
  assert (
    match
      run
        (existing
        @ [ create (response id) ]
        @ post "created"
        @ [ start (response ~code:125 "") ])
    with
    | Error
        { cause = Runtime _; completed = [ "podman --remote=false create" ] } ->
        true
    | _ -> false);
  let parsed_image = Result.get_ok (Podman.decode_image (image ())) in
  let base = Result.get_ok (Podman.decode_container (container ())) in
  let keep =
    {
      loaded with
      identity =
        Keep_id
          {
            name = "dev";
            host = { uid = 42; gid = 43 };
            container = { uid = 1000; gid = 1001 };
          };
    }
  in
  let c =
    {
      base with
      user = "dev";
      userns = "keep-id:gid=1001,uid=1000";
      labels =
        ("dev.deco.user-identity", "uid:1000,gid:1001")
        ::
        (match labels with
        | `Assoc xs ->
            List.map (fun (k, v) -> (k, Yojson.Basic.Util.to_string v)) xs
        | _ -> assert false);
    }
  in
  assert (Assemble.compatibility keep parsed_image c = Ok ());
  List.iter
    (fun c ->
      assert (Result.is_error (Assemble.compatibility keep parsed_image c)))
    [
      { c with user = "other" };
      { c with labels = [] };
      { c with userns = "host" };
      { c with userns = "keep-id:uid=1000,gid=2" };
      { c with userns = "keep-id:uid=1000" };
      { c with userns = "keep-id:uid=1000,gid=1001,uid=1000" };
    ]
