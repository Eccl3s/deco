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
  let test mode keep_image batch =
    let c_exists = ref (mode <> "missing" && mode <> "container-missing")
    and i_exists = ref (mode <> "missing" && mode <> "image-missing") in
    let stopped = ref false
    and c_removed = ref false
    and i_removed = ref false in
    let calls = ref [] in
    let labels owner =
      `Assoc
        [
          ("dev.deco.managed", `String "true");
          ("dev.deco.project", `String owner);
          ("dev.deco.project-root", `String "/project");
        ]
    in
    let json value = Yojson.Basic.to_string (`List [ value ]) in
    let response ?(code = 0) stdout =
      Ok { Process.status = Unix.WEXITED code; stdout; stderr = "" }
    in
    let run argv =
      calls := argv :: !calls;
      match argv with
      | [ "podman"; "--remote=false"; "version" ] -> response ""
      | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; target ] ->
          if !c_removed then assert (target = "cid");
          if not !c_exists then response ~code:125 ""
          else
            response
              (json
                 (`Assoc
                    [
                      ("Id", `String "cid");
                      ("Image", `String "different-image");
                      ( "State",
                        `Assoc
                          [
                            ( "Status",
                              `String
                                (if mode = "paused" then "paused"
                                 else if !stopped || mode = "stopped" then
                                   "exited"
                                 else "running") );
                          ] );
                      ( "Config",
                        `Assoc
                          [
                            ( "Labels",
                              labels
                                (if mode = "container-owner" then "foreign"
                                 else "example") );
                          ] );
                      ("HostConfig", `Assoc [ ("UsernsMode", `String "") ]);
                      ("Mounts", `List []);
                    ]))
      | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; target ] ->
          assert (not keep_image);
          if not !i_exists then response ~code:125 ""
          else
            response
              (json
                 (`Assoc
                    [
                      ( "Id",
                        `String
                          (if mode = "retag" && !c_removed && target <> "iid"
                           then "new-id"
                           else "iid") );
                      ( "Labels",
                        labels
                          (if mode = "image-owner" then "foreign" else "example")
                      );
                      ("Config", `Assoc []);
                    ]))
      | [ "podman"; "--remote=false"; kind; "exists"; "--"; _ ] ->
          response
            ~code:
              (if if kind = "container" then !c_exists else !i_exists then 0
               else 1)
            ""
      | [ "podman"; "--remote=false"; "stop"; "--"; "cid" ] ->
          if mode = "stop-failure" then response ~code:125 ""
          else (
            stopped := true;
            response "")
      | [ "podman"; "--remote=false"; "container"; "rm"; "--"; "cid" ] ->
          if mode = "container-failure" then response ~code:125 ""
          else (
            c_removed := true;
            c_exists := mode = "container-verification";
            response "")
      | [ "podman"; "--remote=false"; "image"; "rm"; "--no-prune"; "--"; "iid" ]
        ->
          if mode = "image-failure" then response ~code:125 ""
          else (
            i_removed := true;
            i_exists := mode = "image-verification";
            response "")
      | argv when argv = Podman_command.list_containers ->
          assert (not keep_image);
          if mode = "bad-list" then response "bad"
          else if mode = "dependencies" then
            response
              {|[{"Id":"z","ImageID":"iid","Names":["stopped"]},{"Id":"a","ImageID":"iid","Names":["running"]}]|}
          else
            response
              {|[{"Id":"other","ImageID":"child-image","Names":["unrelated"]}]|}
      | _ -> failwith ("Unexpected remove command " ^ String.concat " " argv)
    in
    let read_many commands =
      assert (
        commands
        = [
            Podman_command.version;
            Podman_command.inspect "container" "example-dev-container";
          ]
          @
          if keep_image then []
          else [ Podman_command.inspect "image" "example-dev-image:latest" ]);
      List.map run commands
    in
    let result =
      Remove.run ~run
        ?read_many:(if batch then Some read_many else None)
        loaded ~keep_image
    in
    assert (List.length (List.filter (( = ) Podman_command.version) !calls) = 1);
    (if
       (keep_image && mode = "image-owner")
       || mode = "ok" || mode = "stopped" || mode = "missing"
       || mode = "container-missing" || mode = "image-missing"
     then (
       let outcome = Result.get_ok result in
       assert (
         outcome.Remove.container_removed = !c_removed
         && outcome.image_removed = !i_removed);
       assert (outcome.stopped = !stopped))
     else
       match result with
       | Ok _ -> failwith ("Expected failure: " ^ mode)
       | Error e -> (
           let expected =
             (if !stopped then [ Remove.Stop_container ] else [])
             @ (if !c_removed then [ Remove.Remove_container ] else [])
             @ if !i_removed then [ Remove.Remove_image ] else []
           in
           assert (e.Remove.completed = expected);
           if mode = "dependencies" then
             match e.cause with
             | Remove.Image_in_use [ a; b ] ->
                 assert (a.Podman.id = "a" && b.Podman.id = "z")
             | _ -> assert false));
    if keep_image then
      List.iter
        (fun args ->
          assert (
            (not (List.mem "image" args))
            && args <> Podman_command.list_containers))
        !calls
  in
  List.iter
    (fun mode -> List.iter (test mode false) [ false; true ])
    [
      "ok";
      "stopped";
      "missing";
      "container-missing";
      "image-missing";
      "paused";
      "container-owner";
      "image-owner";
      "stop-failure";
      "container-failure";
      "container-verification";
      "bad-list";
      "dependencies";
      "retag";
      "image-failure";
      "image-verification";
    ];
  List.iter
    (fun mode -> List.iter (test mode true) [ false; true ])
    [ "ok"; "missing"; "image-owner" ];
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
      (Remove.run
         ~run:(fun _ -> failwith "Invalid plan invoked runner")
         invalid ~keep_image:false));
  List.iter
    (fun stdout ->
      assert (
        Result.is_error
          (Podman.list_containers
             ~run:(fun command ->
               assert (command = Podman_command.list_containers);
               Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" })
             ())))
    [ "bad"; "{}"; "[{}]"; {|[{"Id":"c","ImageID":"i","Names":42}]|} ]
