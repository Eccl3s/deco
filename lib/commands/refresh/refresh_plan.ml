type t = {
  container_name : string;
  image_reference : string;
  keep_image : bool;
  stop : Command_plan.argument list;
  remove_container : Command_plan.argument list;
  build : string list option;
  create : Command_plan.argument list;
  start : Command_plan.argument list;
}

let make (loaded : Config_loader.t) ~keep_image =
  match Assemble_plan.make loaded with
  | Error e -> Error e
  | Ok assemble -> (
      match Remove_plan.make loaded ~keep_image:true with
      | Error e -> Error e
      | Ok remove ->
          let start =
            (List.find
               (fun (step : Assemble_plan.step) ->
                 step.operation = Assemble_plan.Start)
               assemble.steps)
              .command
          in
          Ok
            {
              container_name = assemble.container_name;
              image_reference = assemble.image_name;
              keep_image;
              stop = remove.stop;
              remove_container = remove.remove_container;
              build = (if keep_image then None else Some assemble.build);
              create = assemble.create;
              start;
            })

let render plan =
  let quote = Command_plan.quote in
  let block command = Command_plan.render_multiline command ^ "\n" in
  "Refresh preview\nNo commands will be run.\n\n"
  ^ "1. Check Podman availability and inspect container "
  ^ quote plan.container_name ^ " and image " ^ quote plan.image_reference
  ^ ".\n"
  ^ "   Verify project ownership of existing resources before changing anything.\n"
  ^ (if plan.keep_image then
       "   The image must already exist; a missing image is a conflict.\n"
     else "")
  ^ (match plan.build with
    | Some build ->
        "2. Rebuild image " ^ quote plan.image_reference
        ^ " while the existing container keeps running:\n"
        ^ block (List.map (fun s -> Command_plan.Literal s) build)
    | None ->
        "2. Keep the existing image " ^ quote plan.image_reference
        ^ "; it is not rebuilt.\n")
  ^ "3. If the container is running, stop it and verify shutdown (destructive):\n"
  ^ block plan.stop
  ^ "4. If the container exists, remove it and verify absence (destructive):\n"
  ^ block plan.remove_container
  ^ "5. Create the replacement container " ^ quote plan.container_name ^ ":\n"
  ^ block plan.create ^ "6. Start the container and verify it is running:\n"
  ^ block plan.start
  ^ "\nIf the container is missing, steps 3 and 4 are skipped.\n"
  ^ "A failed build leaves the existing container unchanged.\n"
  ^ "A failure after step 4 leaves no project container; the old container is \
     not restored.\n"
  ^ "If a container with the configured name appears after step 4, refresh \
     fails instead of reusing it.\n"
  ^ "Lifecycle hooks and named volumes are not applied in this version.\n\n"
  ^ "<container-id> and <image-id> are resolved by inspection during execution.\n"
