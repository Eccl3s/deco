type t = {
  container_name : string;
  image_reference : string option;
  stop : Command_plan.argument list;
  remove_container : Command_plan.argument list;
  remove_image : Command_plan.argument list option;
  pre_stop : string option;
}

let make ?(hooks = true) (loaded : Config_loader.t) ~keep_image =
  let symbolic placeholder argv =
    List.mapi
      (fun i value ->
        if i = List.length argv - 1 then placeholder
        else Command_plan.Literal value)
      argv
  in
  let container_name = loaded.effective.container.name in
  let image_reference =
    if keep_image then None
    else Some (Config.Effective.image_reference loaded.effective.image)
  in
  let stop = symbolic Command_plan.Container_id (Podman_command.stop "") in
  let remove_container =
    symbolic Command_plan.Container_id (Podman_command.remove_container "")
  in
  let remove_image =
    if keep_image then None
    else Some (symbolic Command_plan.Image_id (Podman_command.remove_image ""))
  in
  let names = container_name :: Option.to_list image_reference in
  let commands = stop :: remove_container :: Option.to_list remove_image in
  if
    List.exists (fun s -> String.contains s '\000') names
    || List.exists Command_plan.contains_nul commands
  then Error "Command arguments cannot contain NUL bytes"
  else
    Ok
      {
        container_name;
        image_reference;
        stop;
        remove_container;
        remove_image;
        pre_stop = Stop_plan.pre_stop_step loaded ~hooks;
      }

let render plan =
  "Remove preview\nNo commands will be run.\n\n"
  ^ Command_plan.render_steps
      ([
         "Check Podman availability and inspect container "
         ^ Command_plan.quote plan.container_name
         ^ (match plan.image_reference with
           | None -> "."
           | Some reference ->
               " and image " ^ Command_plan.quote reference ^ ".")
         ^ "\n\
           \   Verify project ownership and supported container state before \
            changing selected resources.";
       ]
      @ Option.to_list plan.pre_stop
      @ [
          "If the container is running, stop it and verify shutdown:\n"
          ^ Command_plan.render_multiline plan.stop;
          "If the container exists, remove it and verify absence:\n"
          ^ Command_plan.render_multiline plan.remove_container;
        ]
      @
      match plan.remove_image with
      | None -> []
      | Some command ->
          [
            "If the image exists, check remaining dependent containers.\n\
            \   If any remain, retain the image and report a conflict.";
            "Otherwise, remove the owned image and verify absence:\n"
            ^ Command_plan.render_multiline command;
          ])
  ^ (match plan.remove_image with
    | None -> "The image is kept; no image operations are planned.\n"
    | Some _ -> "")
  ^ "Missing selected resources are successful no-ops.\n\n" ^ "<container-id>"
  ^ (if Option.is_some plan.remove_image then " and <image-id> are" else " is")
  ^ " resolved by inspection during execution.\n"
