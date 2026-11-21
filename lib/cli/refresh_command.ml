let[@warning "-42"] execute selection dry_run keep_image =
  let open Config.Effective in
  match Cli_common.load_project selection with
  | Error code -> code
  | Ok loaded -> (
      if dry_run then (
        match Deco.Refresh_plan.make loaded ~keep_image with
        | Error message ->
            prerr_endline ("deco: " ^ message);
            2
        | Ok plan ->
            print_string (Deco.Refresh_plan.render plan);
            0)
      else
        let effective = loaded.Deco.Config_loader.effective in
        let container = effective.container.name in
        let image = Config.Effective.image_reference effective.image in
        let runners = Build_output.runners ~label:"Starting" ~image in
        (* Report each stage as it completes so the output follows the real
           order. The status line is closed before the final line. *)
        let progress = function
          | Deco.Refresh.Image_rebuilt ->
              print_endline ("Rebuilt image " ^ image)
          | Deco.Refresh.Image_kept ->
              print_endline ("Kept image " ^ image ^ " (--keep-image)")
          | Deco.Refresh.Container_removed { stopped = true } ->
              print_endline ("Stopped and removed container " ^ container)
          | Deco.Refresh.Container_removed { stopped = false } ->
              print_endline ("Removed container " ^ container)
          | Deco.Refresh.No_container ->
              print_endline ("No existing container: " ^ container)
          | Deco.Refresh.Container_started ->
              runners.Build_output.close true;
              print_endline ("Created and started " ^ container)
        in
        let result =
          try
            Deco.Refresh.run ~read_many:runners.Build_output.read_many
              ~execute:runners.Build_output.execute ~progress loaded ~keep_image
          with e ->
            runners.Build_output.close false;
            raise e
        in
        runners.Build_output.close (Result.is_ok result);
        match result with
        | Ok _ -> 0
        | Error error ->
            let message, code =
              match error.Deco.Refresh.cause with
              | Deco.Refresh.Planning e -> (e, 2)
              | Deco.Refresh.Conflict e -> (e, 4)
              | Deco.Refresh.Runtime e -> (e, 1)
              | Deco.Refresh.Container_appeared ->
                  ( "A container named " ^ container
                    ^ " appeared during refresh and was not replaced; run deco \
                       refresh again.",
                    4 )
              | Deco.Refresh.Podman (Deco.Podman.Unavailable e) -> (e, 3)
              | Deco.Refresh.Podman
                  ( Deco.Podman.Runtime { operation; message }
                  | Deco.Podman.Invalid_response { operation; message } ) ->
                  (operation ^ ": " ^ message, 1)
            in
            prerr_endline ("deco: " ^ message);
            List.iter
              (fun mutation ->
                prerr_endline
                  ("deco: Completed command: "
                  ^
                  match mutation with
                  | Deco.Refresh.Stop_container -> "container stop."
                  | Deco.Refresh.Remove_container -> "container removal."
                  | Deco.Refresh.Build_image -> "image build."
                  | Deco.Refresh.Create_container -> "container creation."
                  | Deco.Refresh.Start_container -> "container start."))
              error.Deco.Refresh.completed;
            let completed mutation =
              List.mem mutation error.Deco.Refresh.completed
            in
            if
              error.Deco.Refresh.cause <> Deco.Refresh.Container_appeared
              && completed Deco.Refresh.Remove_container
              && not (completed Deco.Refresh.Start_container)
            then
              prerr_endline
                ("deco: Refresh is incomplete: the old container " ^ container
               ^ " was removed and no replacement is running. Fix the problem \
                  and run deco refresh again.");
            code)

let command =
  let module Arg = Cmdliner.Arg in
  let module Term = Cmdliner.Term in
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:
            "Preview the complete refresh without invoking Podman, except to \
             locate a $(b,--project).")
  in
  let keep_image =
    Arg.(
      value & flag
      & info [ "keep-image" ]
          ~doc:
            "Recreate only the container from the existing configured image \
             instead of rebuilding it.")
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "refresh" ~exits:Cli_common.exits
       ~doc:"Rebuild the image and recreate the development container.")
    Term.(const execute $ Cli_common.project $ dry_run $ keep_image)
