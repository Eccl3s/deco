open Deco

let get = function Ok x -> x | Error e -> failwith e

let contains text fragment =
  let rec loop i =
    i + String.length fragment <= String.length text
    && (String.sub text i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

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
  let plan = get (Start_plan.make loaded) in
  assert (plan.container_name = "example-dev-container");
  assert (
    plan.start
    = [
        Command_plan.Literal "podman";
        Literal "--remote=false";
        Literal "start";
        Literal "--";
        Container_id;
      ]);
  assert (
    Command_plan.resolve ~image_id:"unused" ~container_id:"verified-id"
      plan.start
    = [ "podman"; "--remote=false"; "start"; "--"; "verified-id" ]);
  let expected =
    "Start preview\nNo commands will be run.\n\n"
    ^ "1. Check Podman availability.\n"
    ^ "2. Inspect the configured image and container example-dev-container; \
       verify ownership, compatibility, and supported state. A missing \
       container fails; run deco assemble.\n"
    ^ "3. If the container is not running, start it:\n"
    ^ "    podman --remote=false start \\\n      -- '<container-id>'"
    ^ "\n   Already-running containers require no mutation.\n"
    ^ "4. After starting, reinspect the same container and verify its ID, \
       ownership, compatibility, and running state.\n"
    ^ "The post_start hook is deferred in v0.1.0 and is not run.\n\n"
    ^ "<container-id> is resolved by inspection during execution.\n"
  in
  assert (Start_plan.render plan = expected);
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
  let custom = get (Start_plan.make (rename "custom-container")) in
  assert (custom.container_name = "custom-container");
  assert (contains (Start_plan.render custom) "container custom-container;");
  let quoted = get (Start_plan.make (rename "a 'quoted'; name")) in
  assert (
    contains (Start_plan.render quoted)
      (Command_plan.quote quoted.container_name));
  assert (not (contains (Start_plan.render quoted) "container a 'quoted'"));
  assert (
    Start_plan.make (rename "bad\000name")
    = Error "Command arguments cannot contain NUL bytes")
