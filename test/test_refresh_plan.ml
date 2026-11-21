open Deco

let get = function Ok x -> x | Error e -> failwith e

let contains text fragment =
  let rec loop i =
    i + String.length fragment <= String.length text
    && (String.sub text i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

(* Index of the first occurrence of [fragment], for ordering checks. *)
let index text fragment =
  let rec loop i =
    if i + String.length fragment > String.length text then
      failwith ("Missing fragment: " ^ fragment)
    else if String.sub text i (String.length fragment) = fragment then i
    else loop (i + 1)
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
  let assemble = get (Assemble_plan.make loaded) in
  let remove = get (Remove_plan.make loaded ~keep_image:true) in
  let start =
    (List.find
       (fun (step : Assemble_plan.step) -> step.operation = Assemble_plan.Start)
       assemble.steps)
      .command
  in
  List.iter
    (fun keep_image ->
      let plan = get (Refresh_plan.make loaded ~keep_image) in
      assert (plan.container_name = "example-dev-container");
      assert (plan.image_reference = "example-dev-image:latest");
      assert (plan.keep_image = keep_image);
      (* Commands are shared with assemble and remove, not rebuilt. *)
      assert (plan.stop = remove.stop);
      assert (plan.remove_container = remove.remove_container);
      assert (plan.create = assemble.create);
      assert (plan.start = start);
      assert (plan.build = if keep_image then None else Some assemble.build);
      let resolve = Command_plan.resolve ~image_id:"iid" ~container_id:"cid" in
      assert (resolve plan.stop = Podman_command.stop "cid");
      assert (
        resolve plan.remove_container = Podman_command.remove_container "cid");
      assert (resolve plan.start = Podman_command.start "cid");
      assert (List.nth (List.rev (resolve plan.create)) 0 = "iid");
      let preview = Refresh_plan.render plan in
      List.iter
        (fun text ->
          if not (contains preview text) then
            failwith ("Missing from preview: " ^ text ^ "\n" ^ preview))
        [
          "Refresh preview";
          "No commands will be run";
          "container example-dev-container";
          "image example-dev-image:latest";
          "Verify project ownership";
          "(destructive)";
          "steps 3 and 4 are skipped";
          "failed build leaves the existing container unchanged";
          "fails instead of reusing it";
          "old container is not restored";
          "hooks and named volumes are not applied";
          "<container-id>";
          "<image-id>";
        ];
      (* Steps appear in execution order. *)
      let order =
        [
          "1. Check Podman availability";
          "2. ";
          "3. If the container is running";
          "4. If the container exists";
          "5. Create the replacement container";
          "6. Start the container";
        ]
      in
      let positions = List.map (index preview) order in
      assert (positions = List.sort compare positions);
      assert (contains preview "podman --remote=false build" = not keep_image);
      assert (contains preview "2. Rebuild image" = not keep_image);
      (* The rebuild happens while the old container still exists. *)
      if not keep_image then
        assert (
          index preview "podman --remote=false build"
          < index preview "podman --remote=false stop");
      assert (contains preview "Keep the existing image" = keep_image);
      assert (contains preview "missing image is a conflict" = keep_image);
      List.iter
        (fun text -> assert (not (contains preview text)))
        [ "--volumes"; "--force"; "--no-prune" ];
      assert (
        preview
        = Refresh_plan.render (get (Refresh_plan.make loaded ~keep_image))))
    [ false; true ];
  (* Planner errors pass through unchanged. *)
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
        Refresh_plan.make bad_container ~keep_image
        = Error "Command arguments cannot contain NUL bytes"))
    [ false; true ]
