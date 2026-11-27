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
          protected = [];
          deco_protection = Not_applicable;
          git_protection = Not_applicable;
        };
      identity = User_identity.Image;
    }
  in
  assert (
    Podman_command.remove_container "-id"
    = [ "podman"; "--remote=false"; "container"; "rm"; "--"; "-id" ]);
  assert (
    Podman_command.remove_image "-id"
    = [ "podman"; "--remote=false"; "image"; "rm"; "--no-prune"; "--"; "-id" ]);
  let contains text fragment =
    let rec loop i =
      i + String.length fragment <= String.length text
      && (String.sub text i (String.length fragment) = fragment || loop (i + 1))
    in
    loop 0
  in
  List.iter
    (fun keep_image ->
      let plan = get (Remove_plan.make loaded ~keep_image) in
      assert (plan.container_name = "example-dev-container");
      assert (
        plan.image_reference
        = if keep_image then None else Some "example-dev-image:latest");
      assert (
        plan.remove_image
        =
        if keep_image then None
        else
          Some
            [
              Command_plan.Literal "podman";
              Literal "--remote=false";
              Literal "image";
              Literal "rm";
              Literal "--no-prune";
              Literal "--";
              Image_id;
            ]);
      let resolve = Command_plan.resolve ~image_id:"iid" ~container_id:"cid" in
      assert (resolve plan.stop = Podman_command.stop "cid");
      assert (
        resolve plan.remove_container = Podman_command.remove_container "cid");
      Option.iter
        (fun command ->
          assert (resolve command = Podman_command.remove_image "iid"))
        plan.remove_image;
      let preview = Remove_plan.render plan in
      List.iter
        (fun text -> assert (contains preview text))
        [
          "Remove preview";
          "No commands will be run";
          "If the container is running";
          "verify shutdown";
          "verify absence";
          "successful no-ops";
          "<container-id>";
        ];
      List.iter
        (fun text -> assert (not (contains preview text)))
        [ "--force"; "--volumes"; "hook" ];
      assert (contains preview "remaining dependent containers" = not keep_image);
      assert (contains preview "<image-id>" = not keep_image);
      assert (contains preview "--no-prune" = not keep_image);
      assert (contains preview "example-dev-image:latest" = not keep_image);
      assert (
        preview = Remove_plan.render (get (Remove_plan.make loaded ~keep_image))))
    [ false; true ];
  let custom =
    {
      loaded with
      effective =
        {
          loaded.effective with
          container = { loaded.effective.container with name = "custom 'name" };
          image = { name = "custom-image"; tag = "custom-tag" };
        };
    }
  in
  let plan = get (Remove_plan.make custom ~keep_image:false) in
  assert (
    plan.container_name = "custom 'name"
    && plan.image_reference = Some "custom-image:custom-tag");
  assert (
    contains (Remove_plan.render plan) (Command_plan.quote plan.container_name));
  let bad_container =
    {
      loaded with
      effective =
        {
          loaded.effective with
          container = { loaded.effective.container with name = "bad\000name" };
        };
    }
  in
  List.iter
    (fun keep_image ->
      assert (
        Remove_plan.make bad_container ~keep_image
        = Error "Command arguments cannot contain NUL bytes"))
    [ false; true ];
  List.iter
    (fun image ->
      let invalid =
        { loaded with effective = { loaded.effective with image } }
      in
      assert (
        Remove_plan.make invalid ~keep_image:false
        = Error "Command arguments cannot contain NUL bytes");
      assert (Result.is_ok (Remove_plan.make invalid ~keep_image:true)))
    [
      { Config.Effective.name = "bad\000image"; tag = "latest" };
      { name = "image"; tag = "bad\000tag" };
    ]
