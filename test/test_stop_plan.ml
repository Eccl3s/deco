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
  assert (
    Podman_command.stop "-container name"
    = [ "podman"; "--remote=false"; "stop"; "--"; "-container name" ]);
  let plan = get (Stop_plan.make loaded) in
  assert (plan.container_name = "example-dev-container");
  assert (
    plan.stop
    = [
        Command_plan.Literal "podman";
        Literal "--remote=false";
        Literal "stop";
        Literal "--";
        Container_id;
      ]);
  assert (
    Command_plan.resolve ~image_id:"unused" ~container_id:"verified-id"
      plan.stop
    = [ "podman"; "--remote=false"; "stop"; "--"; "verified-id" ]);
  let expected =
    "Stop preview\nNo commands will be run.\n\n"
    ^ "1. Check Podman availability.\n"
    ^ "2. Inspect container example-dev-container and verify project ownership \
       and supported state.\n" ^ "3. If the container is running, stop it:\n"
    ^ "    podman --remote=false stop \\\n      -- '<container-id>'"
    ^ "\n   Already-stopped containers require no mutation.\n"
    ^ "4. After stopping, reinspect the same container and verify its ID, \
       ownership, and stopped state.\n\n"
    ^ "<container-id> is resolved by inspection during execution.\n"
  in
  assert (Stop_plan.render plan = expected);
  let rename name =
    {
      loaded with
      effective =
        {
          loaded.effective with
          container = { loaded.effective.container with name };
        };
    }
  in
  let custom = get (Stop_plan.make (rename "custom-container")) in
  assert (custom.container_name = "custom-container");
  let quoted = get (Stop_plan.make (rename "a 'quoted'; name")) in
  let contains text fragment =
    let rec loop i =
      i + String.length fragment <= String.length text
      && (String.sub text i (String.length fragment) = fragment || loop (i + 1))
    in
    loop 0
  in
  assert (
    contains (Stop_plan.render quoted)
      (Command_plan.quote quoted.container_name));
  List.iter
    (fun word -> assert (not (contains (Stop_plan.render plan) word)))
    [ "image"; "compatibility"; "SELinux"; "hook" ];
  assert (
    Stop_plan.make (rename "bad\000name")
    = Error "Command arguments cannot contain NUL bytes")
