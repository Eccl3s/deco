open Deco

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname='example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      source;
      effective;
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [];
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
  (* The create-settings digest: no label means every setting was unset, which
     matches while no setting contributes; a recorded digest must match. *)
  let digest value =
    { c with labels = c.labels @ [ (Create_settings.label, value) ] }
  in
  let current = digest (Create_settings.of_loaded loaded) in
  let settings =
    "Container settings differ from the configuration; run deco refresh"
  in
  assert (Container_runtime.incompatibilities loaded image current = []);
  assert (
    Container_runtime.incompatibilities loaded image
      (digest (Create_settings.digest [ ("container.cap_drop", "ALL") ]))
    = [ settings ]);
  assert (
    Container_runtime.incompatibilities loaded image (digest "garbage")
    = [ settings ]);
  assert (
    Container_runtime.incompatibilities loaded image
      {
        current with
        labels =
          current.labels
          @ [ (Create_settings.label, Create_settings.of_loaded loaded) ];
      }
    = [ "Create-settings label is duplicated" ]);
  (* Reported after the field-by-field checks. *)
  assert (
    Container_runtime.incompatibilities loaded image
      { (digest "garbage") with init = false }
    = [ "Container init is disabled"; settings ]);
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
  (* Concurrent reads: the two initial inspections are batched once, after
     the availability check, and their results are used without re-running
     them. *)
  calls := [];
  let batches = ref [] in
  let read_many commands =
    batches := commands :: !batches;
    List.map (execute Process.Capture) commands
  in
  let initial =
    [
      Podman_command.inspect "image" "example-dev-image:latest";
      Podman_command.inspect "container" "example-dev-container";
    ]
  in
  assert (Result.is_ok (Assemble.run ~execute ~read_many loaded));
  assert (!batches = [ initial ]);
  assert (List.rev_map snd !calls = Podman_command.version :: initial);
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
      contents = "";
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [];
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
  let container ?(state = "created") ?(image_id = "iid") ?(labels = labels)
      ?(cid = id) () =
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String cid);
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
  let executed = ref [] in
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
    executed := [];
    let execute output argv =
      executed := argv :: !executed;
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
  let refused resource summary script =
    match run script with
    | Error { cause = Conflict message; completed = [] } ->
        let expected = resource ^ " " ^ summary in
        let actual =
          match String.index_opt message '\n' with
          | Some i -> String.sub message 0 i
          | None -> message
        in
        if actual <> expected then failwith (actual ^ " <> " ^ expected)
    | _ -> failwith "expected an ownership conflict before any mutation"
  in
  List.iter
    (fun (labels, summary) ->
      refused "image example-dev-image:latest" summary
        [ info; ie (response ""); ii ~labels () ];
      refused "container example-dev-container" summary
        [ info; ie (response ""); ii (); ce (response ""); ci ~labels () ])
    [
      ( owned_by "/old/project",
        "belongs to a Deco project with the same name at another location" );
      (owned_by ~project:"other" "/other", "belongs to Deco project \"other\"");
      ( owned_by ~managed:"false" "/project",
        "exists but was not created by Deco" );
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
  (* Characterization: exact causes and completed mutations for every failure
     path, so restructuring the executor cannot change them silently. *)
  let expect ?(completed = []) cause script =
    match run script with
    | Error e when e.Assemble.cause = cause && e.completed = completed -> ()
    | Error { cause = Conflict m | Runtime m | Planning m; completed = c } ->
        failwith (Printf.sprintf "got %S after [%s]" m (String.concat "; " c))
    | Error _ -> failwith "unexpected Podman error"
    | Ok _ -> failwith "expected a failure"
  in
  let invalid ?(completed = []) operation script =
    match run script with
    | Error
        {
          cause = Podman (Invalid_response { operation = o; _ });
          completed = c;
        }
      when o = operation && c = completed ->
        ()
    | _ -> failwith ("expected an invalid " ^ operation ^ " response")
  in
  let created = [ "podman --remote=false create" ] in
  let built_only = [ "podman --remote=false build" ] in
  let new_container = existing @ [ create (response id) ] @ post "created" in
  (* A container whose configured image is missing is refused before any
     build. *)
  expect (Conflict "Existing container has no configured image")
    [ info; ie (response ~code:1 ""); ce (response ""); ci () ];
  (* Resources that vanish after a mutation. *)
  expect ~completed:built_only (Runtime "Resource missing after mutation")
    (missing @ [ build (response ""); ie (response ~code:1 "") ]);
  expect ~completed:created (Runtime "Resource missing after mutation")
    (existing
    @ [
        create (response id);
        read (Podman_command.exists "container" id) (response ~code:1 "");
      ]);
  expect
    ~completed:(created @ [ "podman --remote=false start" ])
    (Runtime "Resource missing after mutation")
    (new_container
    @ [
        start (response id);
        read (Podman_command.exists "container" id) (response ~code:1 "");
      ]);
  (* Post-mutation inspections re-check identity, compatibility and state. *)
  expect ~completed:created (Conflict "Container ID differs")
    (existing
    @ [
        create (response id);
        read
          (Podman_command.inspect "container" id)
          (response (container ~cid:(String.make 64 'b') ()));
      ]);
  expect ~completed:created (Conflict "Container image differs")
    (existing
    @ [
        create (response id);
        read
          (Podman_command.inspect "container" id)
          (response (container ~image_id:"other" ()));
      ]);
  expect
    ~completed:(created @ [ "podman --remote=false start" ])
    (Runtime "Container is not running after start")
    (new_container @ [ start (response id) ] @ post "exited");
  (* Undecodable inspections. *)
  invalid "image inspect"
    [
      info;
      read
        (Podman_command.inspect "image" "example-dev-image:latest")
        (response "bad");
    ];
  invalid "container inspect"
    [
      info;
      ie (response "");
      ii ();
      read
        (Podman_command.inspect "container" "example-dev-container")
        (response "bad");
    ];
  invalid ~completed:created "container inspect"
    (existing
    @ [
        create (response id);
        read (Podman_command.inspect "container" id) (response "bad");
      ]);
  (* A failed initial inspection asks Podman whether it is reachable: down is
     reported as unavailable, up as the inspection failure. *)
  let podman_info r = read Podman_command.info r in
  let failed_inspect = "exit 125; existence check: exit 125" in
  expect (Podman (Unavailable "exit 125"))
    [ info; ie (response ~code:125 ""); podman_info (response ~code:125 "") ];
  expect (Runtime failed_inspect)
    [ info; ie (response ~code:125 ""); podman_info (response "") ];
  expect (Runtime failed_inspect)
    [
      info;
      ie (response "");
      ii ();
      ce (response ~code:125 "");
      podman_info (response "");
    ];
  (* After a mutation there is no reachability probe: the script ends at the
     failed inspection. *)
  expect ~completed:built_only (Runtime failed_inspect)
    (missing @ [ build (response ""); ie (response ~code:125 "") ]);
  (* Sequence guard: on the full path, the commands run, ignoring the
     existence fallbacks, are exactly the planned steps in order. This keeps
     --dry-run and execution in step. *)
  assert (
    Result.is_ok
      (run
         (built
         @ [ create (response id) ]
         @ post "created"
         @ [ start (response id) ]
         @ post "running")));
  let ran =
    List.rev !executed |> List.filter (fun argv -> not (List.mem "exists" argv))
  in
  let planned =
    List.map
      (fun (step : Assemble_plan.step) ->
        Assemble_plan.resolve ~image_id:"iid" ~container_id:id step.command)
      plan.steps
  in
  assert (ran = planned);
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

(* Hooks: post_create once after a creation, then post_start after any start,
   both after on_ready and in the verified container; nothing for a running
   container; a failed hook stops later hooks and leaves the container
   running. *)
let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "project.name='example'\n\
          hooks={post_create='echo created',post_start='echo started'}\n")
  in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [];
        };
      identity = Image;
    }
  in
  let id = String.make 64 'b' in
  let labels =
    {|{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":"/project"}|}
  in
  let scenario ?(fail = "") initial =
    let state = ref initial and events = ref [] in
    let response ?(code = 0) stdout =
      Ok { Process.status = Unix.WEXITED code; stdout; stderr = "" }
    in
    let container () =
      Printf.sprintf
        {|[{"Id":"%s","Image":"iid","Config":{"Labels":%s,"User":"","WorkingDir":"/"},"HostConfig":{"Init":true,"UsernsMode":""},"State":{"Status":"%s"},"Mounts":[]}]|}
        id labels !state
    in
    let execute _ argv =
      match argv with
      | [ "podman"; "--remote=false"; "version" ] -> response ""
      | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] ->
          response
            (Printf.sprintf
               {|[{"Id":"iid","Labels":%s,"Config":{"User":"","WorkingDir":"/"}}]|}
               labels)
      | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] ->
          if !state = "absent" then response ~code:125 ""
          else response (container ())
      | [ "podman"; "--remote=false"; "container"; "exists"; "--"; _ ] ->
          response ~code:(if !state = "absent" then 1 else 0) ""
      | "podman" :: "--remote=false" :: "create" :: _ ->
          events := "create" :: !events;
          state := "created";
          response (id ^ "\n")
      | [ "podman"; "--remote=false"; "start"; "--"; _ ] ->
          events := "start" :: !events;
          state := "running";
          response id
      | _ -> failwith ("Unexpected command: " ^ String.concat " " argv)
    in
    let hook argv =
      let name =
        match List.rev argv with
        | "echo created" :: "-c" :: "sh" :: container :: "--" :: _ ->
            assert (container = id);
            "post_create"
        | "echo started" :: "-c" :: "sh" :: container :: "--" :: _ ->
            assert (container = id);
            "post_start"
        | _ -> failwith ("Unexpected hook: " ^ String.concat " " argv)
      in
      events := name :: !events;
      let code = if name = fail then 4 else 0 in
      Ok { Process.status = Unix.WEXITED code; stdout = ""; stderr = "" }
    in
    let on_ready (_ : Assemble.outcome) =
      events := "ready" :: !events;
      Ok ()
    in
    let result = Assemble.run ~execute ~hook ~on_ready loaded in
    (result, List.rev !events, !state)
  in
  (match scenario "absent" with
  | ( Ok { created = true; started = true; _ },
      [ "create"; "start"; "ready"; "post_create"; "post_start" ],
      "running" ) ->
      ()
  | _ -> assert false);
  (match scenario "exited" with
  | ( Ok { created = false; started = true; _ },
      [ "start"; "ready"; "post_start" ],
      "running" ) ->
      ()
  | _ -> assert false);
  (* A container an earlier run created but never started still gets
     post_create before post_start. *)
  (match scenario "created" with
  | ( Ok { created = false; started = true; _ },
      [ "start"; "ready"; "post_create"; "post_start" ],
      "running" ) ->
      ()
  | _ -> assert false);
  (match scenario "running" with
  | Ok { created = false; started = false; _ }, [ "ready" ], "running" -> ()
  | _ -> assert false);
  (match scenario ~fail:"post_create" "absent" with
  | ( Error
        {
          cause =
            Hook (Hook.Exited { hook = Post_create; status = Unix.WEXITED 4 });
          _;
        },
      [ "create"; "start"; "ready"; "post_create" ],
      "running" ) ->
      ()
  | _ -> assert false);
  match scenario ~fail:"post_start" "exited" with
  | ( Error
        {
          cause =
            Hook (Hook.Exited { hook = Post_start; status = Unix.WEXITED 4 });
          _;
        },
      [ "start"; "ready"; "post_start" ],
      "running" ) ->
      ()
  | _ -> assert false

(* An image whose io.containers.capabilities label excludes a cap_add entry:
   Podman would not apply it, so assemble refuses before podman create. *)
let () =
  let loaded text : Config_loader.t =
    let source =
      Result.get_ok
        (Config.Decode.from_string ("project.name='example'\n" ^ text))
    in
    {
      ignored_paths = [];
      contents = "";
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [];
        };
      identity = Image;
    }
  in
  let image label : Podman.image =
    {
      id = "iid";
      labels =
        [
          ("dev.deco.managed", "true");
          ("dev.deco.project", "example");
          ("dev.deco.project-root", "/project");
        ]
        @ Option.to_list
            (Option.map
               (fun v -> (Container_runtime.capabilities_label, v))
               label);
      user = "";
      workdir = "/";
      created = None;
    }
  in
  let unapplied text label =
    Container_runtime.unapplied_capabilities (loaded text) (image label)
  in
  let add = "container.cap_add=['SYS_ADMIN','cap_mknod']" in
  (* Nothing to check without cap_add or without the label. *)
  assert (unapplied "" (Some "CHOWN") = None);
  assert (unapplied add None = None);
  (* Names compare as Podman does: any case, optional CAP_ prefix. *)
  assert (unapplied add (Some "chown,CAP_SYS_ADMIN,mknod") = None);
  (match unapplied add (Some "CHOWN,SETUID") with
  | Some message ->
      assert (
        message
        = "Image example-dev-image:latest sets io.containers.capabilities, \
           which limits containers to these capabilities: CHOWN, SETUID\n\
          \  Podman does not apply container.cap_add entries outside it: \
           SYS_ADMIN, cap_mknod\n\
          \  Remove them from container.cap_add, or build from an image \
           without that label.")
  | None -> assert false);
  (* An empty label allows nothing; ALL is never in the list; values are
     escaped. *)
  (match unapplied add (Some "") with
  | Some message ->
      assert (
        String.length message > 0
        && List.exists
             (String.equal
                "  Podman does not apply container.cap_add entries outside it: \
                 SYS_ADMIN, cap_mknod")
             (String.split_on_char '\n' message))
  | None -> assert false);
  assert (unapplied "container.cap_add=['ALL']" (Some "SYS_ADMIN") <> None);
  (match unapplied add (Some "CHOWN\027[2J") with
  | Some message -> assert (not (String.contains message '\027'))
  | None -> assert false);
  (* Assemble refuses before creating anything, and creates when the label
     allows every entry. *)
  let run text label =
    let created = ref false in
    let execute _ argv =
      let ok stdout =
        Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" }
      in
      match argv with
      | [ "podman"; "--remote=false"; "version" ] -> ok ""
      | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] ->
          ok
            (Printf.sprintf
               {|[{"Id":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":"/project","io.containers.capabilities":"%s"},"Config":{"User":"","WorkingDir":"/"}}]|}
               label)
      | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] ->
          Ok { Process.status = Unix.WEXITED 125; stdout = ""; stderr = "" }
      | [ "podman"; "--remote=false"; "container"; "exists"; "--"; _ ] ->
          Ok { Process.status = Unix.WEXITED 1; stdout = ""; stderr = "" }
      | "podman" :: "--remote=false" :: "create" :: _ ->
          created := true;
          (* Stop here: this test is only about reaching create. *)
          Error { Process.operation = "create"; message = "reached" }
      | _ -> failwith ("Unexpected command: " ^ String.concat " " argv)
    in
    let result = Assemble.run ~execute (loaded text) in
    (result, !created)
  in
  (match run add "CHOWN" with
  | Error { cause = Conflict message; completed = [] }, false ->
      assert (
        String.starts_with ~prefix:"Image example-dev-image:latest" message)
  | _ -> assert false);
  match run add "CHOWN,SYS_ADMIN,MKNOD" with
  | Error { cause = Runtime _; _ }, true -> ()
  | _ -> assert false

(* Podman create receives env files and actual variable values. *)
let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "project.name='example'\n\
          container.env_files=['.env']\n\
          container.environment.TOKEN='SECRET_VALUE'\n")
  in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [ "/project/.env" ];
        };
      identity = Image;
    }
  in
  let created = ref [] in
  let execute _ argv =
    let ok stdout =
      Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" }
    in
    match argv with
    | [ "podman"; "--remote=false"; "version" ] -> ok ""
    | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] ->
        ok
          {|[{"Id":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":"/project"},"Config":{"User":"","WorkingDir":"/"}}]|}
    | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] ->
        Ok { Process.status = Unix.WEXITED 125; stdout = ""; stderr = "" }
    | [ "podman"; "--remote=false"; "container"; "exists"; "--"; _ ] ->
        Ok { Process.status = Unix.WEXITED 1; stdout = ""; stderr = "" }
    | "podman" :: "--remote=false" :: "create" :: _ ->
        created := argv;
        Error { Process.operation = "create"; message = "reached" }
    | _ -> failwith ("Unexpected command: " ^ String.concat " " argv)
  in
  (match Assemble.run ~execute loaded with
  | Error { cause = Runtime _; _ } -> ()
  | _ -> assert false);
  let rec sublist needle = function
    | [] -> false
    | _ :: rest as list ->
        List.filteri (fun i _ -> i < List.length needle) list = needle
        || sublist needle rest
  in
  assert (
    sublist
      [ "--env-file"; "/project/.env"; "--env"; "TOKEN=SECRET_VALUE" ]
      !created)
