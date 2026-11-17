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
  List.iter
    (fun tty ->
      let args = [ "printf"; ""; "a b"; "'"; "$(touch nope)"; "--help" ] in
      let plan = get (Exec_plan.make loaded ~tty args) in
      let resolve =
        Assemble_plan.resolve ~image_id:"unused" ~container_id:"cid"
      in
      assert (resolve plan.start = [ "podman"; "start"; "--"; "cid" ]);
      assert (
        resolve plan.exec
        = [ "podman"; "exec"; "--interactive" ]
          @ (if tty then [ "--tty" ] else [])
          @ [ "--"; "cid" ] @ args);
      assert (Exec_plan.render plan = Exec_plan.render plan);
      let loaded =
        {
          loaded with
          effective =
            {
              loaded.effective with
              container =
                { loaded.effective.container with workdir = Some "/workspace" };
            };
          identity =
            Keep_id
              {
                name = "dev";
                host = { uid = 1; gid = 2 };
                container = { uid = 1000; gid = 1000 };
              };
        }
      in
      let plan = get (Exec_plan.make loaded ~tty [ "true" ]) in
      assert (
        resolve plan.exec
        = [ "podman"; "exec"; "--interactive" ]
          @ (if tty then [ "--tty" ] else [])
          @ [ "--user"; "dev"; "--workdir"; "/workspace"; "--"; "cid"; "true" ]))
    [ false; true ];
  assert (Result.is_error (Exec_plan.make loaded ~tty:false []));
  let rejects loaded command =
    assert (
      Exec_plan.make loaded ~tty:false command
      = Error "Command arguments cannot contain NUL bytes")
  in
  rejects loaded [ "echo"; "bad\000argument" ];
  rejects
    {
      loaded with
      effective =
        {
          loaded.effective with
          container =
            { loaded.effective.container with workdir = Some "/work\000space" };
        };
    }
    [ "true" ];
  rejects
    {
      loaded with
      identity =
        Keep_id
          {
            name = "dev\000user";
            host = { uid = 1; gid = 2 };
            container = { uid = 1000; gid = 1000 };
          };
    }
    [ "true" ]
