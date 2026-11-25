type t = {
  container_name : string;
  image_reference : string;
  keep_image : bool;
  stop : Command_plan.argument list;
  remove_container : Command_plan.argument list;
  build : string list option;
  create : Command_plan.argument list;
  start : Command_plan.argument list;
  pre_stop : string option;
  post_create : Command_plan.argument list option;
  post_start : Command_plan.argument list option;
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
              pre_stop = remove.pre_stop;
              post_create = assemble.post_create;
              post_start = assemble.post_start;
            })

let render plan =
  let quote = Command_plan.quote in
  let block command = Command_plan.render_multiline command in
  let hook name condition = Option.map (Hook.render_step ~condition name) in
  let inspect =
    "Check Podman availability and inspect container "
    ^ quote plan.container_name ^ " and image " ^ quote plan.image_reference
    ^ ".\n\
      \   Verify project ownership of existing resources before changing \
       anything."
    ^
    if plan.keep_image then
      "\n   The image must already exist; a missing image is a conflict."
    else ""
  in
  let image =
    match plan.build with
    | Some build ->
        "Rebuild image " ^ quote plan.image_reference
        ^ " while the existing container keeps running:\n"
        ^ block (List.map (fun s -> Command_plan.Literal s) build)
    | None ->
        "Keep the existing image " ^ quote plan.image_reference
        ^ "; it is not rebuilt."
  in
  let image =
    if
      List.exists
        (function
          | Command_plan.Literal arg ->
              String.starts_with ~prefix:"--cap-add=" arg
          | Redacted _ | Image_id | Container_id -> false)
        plan.create
    then
      image ^ "\n   If the image's " ^ Container_runtime.capabilities_label
      ^ " label excludes a --cap-add entry, stop before changing the container."
    else image
  in
  let before_removal =
    [ inspect; image ]
    @ Option.to_list plan.pre_stop
    @ [
        "If the container is running, stop it and verify shutdown (destructive):\n"
        ^ block plan.stop;
      ]
  in
  let removal = List.length before_removal + 1 in
  let steps =
    before_removal
    @ [
        "If the container exists, remove it and verify absence (destructive):\n"
        ^ block plan.remove_container;
        "Create the replacement container " ^ quote plan.container_name ^ ":\n"
        ^ block plan.create;
        "Start the container and verify it is running:\n" ^ block plan.start;
      ]
    @ Option.to_list
        (hook Hook.Post_create "After creating the replacement" plan.post_create)
    @ Option.to_list
        (hook Hook.Post_start "After starting the replacement" plan.post_start)
  in
  let first_stop = 3 in
  "Refresh preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps steps
  ^ Printf.sprintf
      "\nIf the container is missing, steps %d %s %d are skipped.\n" first_stop
      (if removal = first_stop + 1 then "and" else "to")
      removal
  ^ "A failed build leaves the existing container unchanged.\n"
  ^ (if Option.is_some plan.pre_stop then
       "A failed pre_stop hook leaves the existing container running and \
        unchanged.\n"
     else "")
  ^ Printf.sprintf
      "A failure after step %d is a partial refresh: the old container is not \
       restored.\n"
      removal
  ^ Printf.sprintf
      "If a container with the configured name appears after step %d, refresh \
       fails instead of reusing it.\n"
      removal
  ^ "Named volumes are not applied in this version.\n\n"
  ^ "<container-id> and <image-id> are resolved by inspection during execution.\n"
