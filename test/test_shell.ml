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
    assert (!batches = if batch then 1 else 0);
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
    [ false; true ]
