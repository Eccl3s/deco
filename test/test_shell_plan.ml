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
  let resolve =
    Command_plan.resolve ~image_id:"unused" ~container_id:"verified-id"
  in
  let check (loaded : Config_loader.t) user workdir shell =
    let loaded =
      {
        loaded with
        effective =
          {
            loaded.effective with
            container = { loaded.effective.container with shell; workdir };
          };
      }
    in
    let plan = get (Shell_plan.make loaded) in
    assert (
      resolve plan.exec.Exec_plan.start
      = [ "podman"; "--remote=false"; "start"; "--"; "verified-id" ]);
    assert (
      resolve plan.exec.Exec_plan.exec
      = [ "podman"; "--remote=false"; "exec"; "--interactive"; "--tty" ]
        @ (match user with None -> [] | Some name -> [ "--user"; name ])
        @ (match workdir with None -> [] | Some path -> [ "--workdir"; path ])
        @ [ "--"; "verified-id"; shell ]);
    let expected =
      "Shell preview\nNo commands will be run.\n\n"
      ^ "1. Check Podman availability.\n"
      ^ "2. Inspect the configured image and container; verify ownership, \
         compatibility, and supported state.\n"
      ^ "3. If the container is not running, start it:\n"
      ^ Command_plan.render_multiline plan.exec.Exec_plan.start
      ^ "\n"
      ^ "   Then reinspect the same container and verify ownership, \
         compatibility, and running state.\n"
      ^ "4. Enter the configured interactive shell:\n"
      ^ Command_plan.render_multiline plan.exec.Exec_plan.exec
      ^ "\n\n<container-id> is resolved by inspection during execution.\n"
    in
    assert (Shell_plan.render plan = expected)
  in
  check loaded None None "sh";
  let keep =
    {
      loaded with
      identity =
        User_identity.Keep_id
          {
            name = "dev";
            host = { uid = 1; gid = 2 };
            container = { uid = 1000; gid = 1000 };
          };
    }
  in
  List.iter
    (fun shell ->
      check loaded None (Some "/work space") shell;
      check keep (Some "dev") None shell;
      check keep (Some "dev") (Some "/workspace") shell)
    [ "bash"; "/bin/zsh"; "shell with spaces"; "shell'; $(echo literal)" ];
  let rejects loaded =
    assert (
      Shell_plan.make loaded
      = Error "Command arguments cannot contain NUL bytes")
  in
  List.iter
    (fun (shell, workdir) ->
      rejects
        {
          loaded with
          effective =
            {
              loaded.effective with
              container = { loaded.effective.container with shell; workdir };
            };
        })
    [ ("sh\000bad", None); ("sh", Some "/work\000space") ];
  rejects
    {
      keep with
      identity =
        User_identity.Keep_id
          {
            name = "dev\000bad";
            host = { uid = 1; gid = 2 };
            container = { uid = 1000; gid = 1000 };
          };
    };
  (* Hooks are listed in execution order: post_start after a start, then
     pre_enter immediately before entry. *)
  let render hooks =
    Shell_plan.render
      (get
         (Shell_plan.make
            { loaded with effective = { loaded.effective with hooks } }))
  in
  let none = loaded.effective.hooks in
  let both =
    render { none with post_start = Some "echo a"; pre_enter = Some "echo b" }
  in
  let index fragment =
    let rec loop i =
      if String.sub both i (String.length fragment) = fragment then i
      else loop (i + 1)
    in
    loop 0
  in
  assert (
    index "4. If the container was started, run the post_start hook:"
    < index "5. Immediately before entering, run the pre_enter hook:");
  assert (index "5. Immediately" < index "6. Enter the configured");
  let only = render { none with pre_enter = Some "echo b" } in
  assert (
    String.length only > 0
    &&
    let fragment = "4. Immediately before entering, run the pre_enter hook:" in
    let rec loop i =
      i + String.length fragment <= String.length only
      && (String.sub only i (String.length fragment) = fragment || loop (i + 1))
    in
    loop 0)
