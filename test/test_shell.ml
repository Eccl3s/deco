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
  let json ?(owner = "example") ?(workdir = "/") state =
    let labels =
      match labels with
      | `Assoc fields ->
          `Assoc
            (("dev.deco.project", `String owner)
            :: List.remove_assoc "dev.deco.project" fields)
      | _ -> assert false
    in
    Yojson.Basic.to_string
      (`List
         [
           `Assoc
             [
               ("Id", `String "cid");
               ("Image", `String "iid");
               ("State", `Assoc [ ("Status", `String state) ]);
               ( "Config",
                 `Assoc [ ("Labels", labels); ("WorkingDir", `String workdir) ]
               );
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
          container =
            {
              loaded.effective.container with
              shell = "/bin/custom shell;literal";
            };
        };
    }
  in
  let forbidden _ = failwith "Nonterminal shell touched runtime" in
  assert (
    Shell.run
      ~execute:(fun _ _ -> forbidden ())
      ~read_many:forbidden ~probe:forbidden loaded ~tty:false
    = Error
        {
          Exec.cause =
            Exec.Planning
              "Shell entry requires stdin and stdout to be terminals";
          started = false;
        });
  let test ~state ~failure ~status ~batch =
    let started = ref false and entered = ref false and batches = ref 0 in
    let response ?(code = 0) stdout =
      Ok { Process.status = Unix.WEXITED code; stdout; stderr = "" }
    in
    let execute output argv =
      match argv with
      | [ "podman"; "--remote=false"; "version" ] -> response ""
      | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] ->
          response image
      | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; target ] ->
          assert (output = Process.Capture);
          if !started then assert (target = "cid");
          if failure = "missing" then response ~code:125 ""
          else if failure = "owner" then response (json ~owner:"foreign" state)
          else if failure = "compatibility" then
            response (json ~workdir:"/other" state)
          else
            response
              (json
                 (if !started && failure <> "verify" then "running" else state))
      | [ "podman"; "--remote=false"; "container"; "exists"; "--"; _ ]
        when failure = "missing" ->
          response ~code:1 ""
      | [ "podman"; "--remote=false"; "start"; "--"; "cid" ] ->
          assert (output = Process.Capture);
          if failure = "start" then response ~code:125 ""
          else (
            started := true;
            response "")
      | [
       "podman";
       "--remote=false";
       "exec";
       "--interactive";
       "--tty";
       "--";
       "cid";
       shell;
      ] ->
          assert (
            shell = loaded.effective.container.shell && output = Process.Inherit);
          entered := true;
          if failure = "launch" then
            Error { Process.operation = "launch"; message = "failed" }
          else Ok { Process.status; stdout = ""; stderr = "" }
      | _ -> failwith ("Unexpected shell command: " ^ String.concat " " argv)
    in
    let read_many commands =
      incr batches;
      List.map (execute Process.Capture) commands
    in
    let result =
      Shell.run ~execute
        ?read_many:(if batch then Some read_many else None)
        ~probe:(fun () -> failwith "Unexpected SELinux probe")
        loaded ~tty:true
    in
    assert (!batches = if batch then if !started then 2 else 1 else 0);
    if failure = "" then
      let outcome = Result.get_ok result in
      assert (
        !entered
        && outcome.Exec.status = status
        && outcome.started = (state <> "running"))
    else (
      assert ((not !entered) || failure = "launch");
      match result with
      | Ok _ -> assert false
      | Error error -> (
          assert (error.Exec.started = !started);
          match (failure, error.cause) with
          | "missing", Exec.Conflict message ->
              assert (message = "Container is missing; run deco assemble")
          | ("owner" | "compatibility"), Exec.Conflict _ -> ()
          | ("start" | "verify" | "launch"), Exec.Runtime _ -> ()
          | _ -> assert false))
  in
  List.iter
    (fun batch ->
      List.iter
        (fun state ->
          List.iter
            (fun status -> test ~state ~failure:"" ~status ~batch)
            [ Unix.WEXITED 0; Unix.WEXITED 17; Unix.WSIGNALED Sys.sigterm ])
        [ "running"; "exited" ];
      List.iter
        (fun failure ->
          test ~state:"exited" ~failure ~status:(Unix.WEXITED 0) ~batch)
        [ "missing"; "owner"; "compatibility"; "start"; "verify"; "launch" ])
    [ false; true ];
  (* post_start (after a start) then pre_enter run in the verified container
     before entry; a failed pre_enter prevents entry and keeps its status. *)
  let hooked =
    {
      loaded with
      effective =
        {
          loaded.effective with
          hooks =
            {
              loaded.effective.hooks with
              post_start = Some "echo started";
              pre_enter = Some "echo entering";
            };
        };
    }
  in
  List.iter
    (fun (state, pre_enter_status) ->
      let events = ref [] and started = ref false in
      let response stdout =
        Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" }
      in
      let execute _ argv =
        match argv with
        | [ "podman"; "--remote=false"; "version" ] -> response ""
        | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ] ->
            response image
        | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; _ ] ->
            response (json (if !started then "running" else state))
        | [ "podman"; "--remote=false"; "start"; "--"; "cid" ] ->
            started := true;
            events := "start" :: !events;
            response ""
        | "podman" :: "--remote=false" :: "exec" :: "--interactive" :: _ ->
            events := "shell" :: !events;
            response ""
        | _ -> failwith ("Unexpected shell command: " ^ String.concat " " argv)
      in
      let hook argv =
        let status =
          match List.rev argv with
          | "echo entering" :: "-lc" :: _ :: "cid" :: "--" :: _ ->
              events := "pre_enter" :: !events;
              pre_enter_status
          | "echo started" :: "-lc" :: _ :: "cid" :: "--" :: _ ->
              events := "post_start" :: !events;
              Unix.WEXITED 0
          | _ -> failwith ("Unexpected hook: " ^ String.concat " " argv)
        in
        Ok { Process.status; stdout = ""; stderr = "" }
      in
      let result =
        Shell.run ~execute ~hook
          ~probe:(fun () -> failwith "Unexpected SELinux probe")
          hooked ~tty:true
      in
      let prepared =
        if state = "running" then [] else [ "start"; "post_start" ]
      in
      match (result, pre_enter_status) with
      | Ok _, Unix.WEXITED 0 ->
          assert (List.rev !events = prepared @ [ "pre_enter"; "shell" ])
      | ( Error
            {
              cause = Exec.Hook (Hook.Exited { hook = Pre_enter; status });
              started;
            },
          _ ) ->
          assert (status = pre_enter_status);
          assert (started = (state <> "running"));
          assert (List.rev !events = prepared @ [ "pre_enter" ])
      | _ -> assert false)
    [
      ("running", Unix.WEXITED 0);
      ("exited", Unix.WEXITED 0);
      ("running", Unix.WEXITED 9);
      ("exited", Unix.WEXITED 9);
    ]
