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
          env_files = [];
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
    (* [<kind>-owner] is another project, [<kind>-root] a moved project (or
       another project with the same name elsewhere), [<kind>-unlabelled] a
       resource Deco did not create. *)
    let labels kind =
      if mode = kind ^ "-unlabelled" then `Assoc []
      else
        `Assoc
          [
            ("dev.deco.managed", `String "true");
            ( "dev.deco.project",
              `String (if mode = kind ^ "-owner" then "foreign" else "example")
            );
            ( "dev.deco.project-root",
              `String
                (if mode = kind ^ "-root" then "/old/project" else "/project")
            );
          ]
    in
    let ownership_modes kind =
      List.map (( ^ ) (kind ^ "-")) [ "owner"; "root"; "unlabelled" ]
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
                      ("Config", `Assoc [ ("Labels", labels "container") ]);
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
                      ("Labels", labels "image");
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
       (keep_image && List.mem mode (ownership_modes "image"))
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
           if
             List.mem mode
               (ownership_modes "container" @ ownership_modes "image")
           then (
             assert (not (!stopped || !c_removed || !i_removed));
             let prefix =
               if List.mem mode (ownership_modes "image") then
                 "image example-dev-image:latest "
               else "container example-dev-container "
             in
             match e.cause with
             | Remove.Conflict message when String.starts_with ~prefix message
               ->
                 ()
             | _ -> failwith ("Expected an ownership conflict: " ^ mode));
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
      "container-root";
      "container-unlabelled";
      "image-owner";
      "image-root";
      "image-unlabelled";
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
    [ "ok"; "missing"; "image-owner"; "image-root"; "image-unlabelled" ];
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

(* pre_stop runs before a running container is stopped and removed; a failure
   prevents both, and hooks:false skips it. *)
let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "project.name='example'\nhooks.pre_stop='echo bye'\n")
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
          env_files = [];
        };
      identity = User_identity.Image;
    }
  in
  let scenario ?(hooks = true) ?(hook_status = Unix.WEXITED 0) () =
    let events = ref [] and stopped = ref false and removed = ref false in
    let response ?(code = 0) stdout =
      Ok { Process.status = Unix.WEXITED code; stdout; stderr = "" }
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
                   `Assoc
                     [
                       ( "Labels",
                         `Assoc
                           [
                             ("dev.deco.managed", `String "true");
                             ("dev.deco.project", `String "example");
                             ("dev.deco.project-root", `String "/project");
                           ] );
                     ] );
                 ("HostConfig", `Assoc [ ("UsernsMode", `String "") ]);
                 ("Mounts", `List []);
               ];
           ])
    in
    let run argv =
      match argv with
      | [ "podman"; "--remote=false"; "version" ] -> response ""
      | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] ->
          if !removed then response ~code:125 ""
          else response (container (if !stopped then "exited" else "running"))
      | [ "podman"; "--remote=false"; "container"; "exists"; "--"; _ ] ->
          response ~code:1 ""
      | [ "podman"; "--remote=false"; "stop"; "--"; "cid" ] ->
          events := "stop" :: !events;
          stopped := true;
          response ""
      | [ "podman"; "--remote=false"; "container"; "rm"; "--"; "cid" ] ->
          events := "rm" :: !events;
          removed := true;
          response ""
      | _ -> failwith ("Unexpected command: " ^ String.concat " " argv)
    in
    let hook _ =
      events := "pre_stop" :: !events;
      Ok { Process.status = hook_status; stdout = ""; stderr = "" }
    in
    let result = Remove.run ~run ~hooks ~hook loaded ~keep_image:true in
    (result, List.rev !events)
  in
  (match scenario () with
  | ( Ok { container_removed = true; stopped = true; _ },
      [ "pre_stop"; "stop"; "rm" ] ) ->
      ()
  | _ -> assert false);
  (match scenario ~hooks:false () with
  | Ok { container_removed = true; _ }, [ "stop"; "rm" ] -> ()
  | _ -> assert false);
  match scenario ~hook_status:(Unix.WEXITED 6) () with
  | ( Error
        {
          cause =
            Remove.Hook (Hook.Exited { hook = Pre_stop; status = WEXITED 6 });
          completed = [];
        },
      [ "pre_stop" ] ) ->
      ()
  | _ -> assert false
