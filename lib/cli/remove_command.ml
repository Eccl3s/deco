let[@warning "-42"] execute selection dry_run keep_image no_hooks =
  let open Config.Effective in
  match
    Cli_common.load_trusted_project ~no_hooks ~command:"remove" ~dry_run
      selection
  with
  | Error code -> code
  | Ok loaded -> (
      if dry_run then (
        match
          Deco.Remove_plan.make ~hooks:(not no_hooks) loaded ~keep_image
        with
        | Error message ->
            prerr_endline ("deco: " ^ message);
            2
        | Ok plan ->
            print_string (Deco.Remove_plan.render plan);
            0)
      else
        (* [remove --force], which still requires trust with [--no-hooks]
           (specs/deco-trust.md §6), does not exist yet. *)
        match
          Deco.Remove.run
            ~read_many:(fun commands ->
              Deco.Process.run_many ~forward_signals:true commands)
            ~run:(fun argv -> Deco.Process.run ~forward_signals:true argv)
            ~hooks:(not no_hooks)
            ~warn:(fun message -> prerr_endline ("deco: " ^ message))
            loaded ~keep_image
        with
        | Ok outcome ->
            Printf.printf "%s %s\n"
              (if outcome.Deco.Remove.container_removed then "Removed container"
               else "Container already absent:")
              loaded.Deco.Config_loader.effective.container.name;
            if keep_image then
              print_endline "Image removal skipped (--keep-image)."
            else
              Printf.printf "%s %s:%s\n"
                (if outcome.Deco.Remove.image_removed then "Removed image"
                 else "Image already absent:")
                loaded.Deco.Config_loader.effective.image.name
                loaded.Deco.Config_loader.effective.image.tag;
            0
        | Error error ->
            let message, code =
              match error.Deco.Remove.cause with
              | Deco.Remove.Planning e -> (e, 2)
              | Deco.Remove.Conflict e -> (e, 4)
              | Deco.Remove.Runtime e -> (e, 1)
              | Deco.Remove.Hook failure ->
                  ( Deco.Hook.failure_message failure
                    ^ "; nothing was stopped or removed",
                    Deco.Hook.exit_status failure )
              | Deco.Remove.Image_in_use _ ->
                  ("Image is still used by dependent containers:", 4)
              | Deco.Remove.Podman (Deco.Podman.Unavailable e) -> (e, 3)
              | Deco.Remove.Podman
                  ( Deco.Podman.Runtime { operation; message }
                  | Deco.Podman.Invalid_response { operation; message } ) ->
                  (operation ^ ": " ^ message, 1)
            in
            prerr_endline ("deco: " ^ message);
            (match error.Deco.Remove.cause with
            | Deco.Remove.Image_in_use dependents ->
                List.iter
                  (fun (dependent : Deco.Podman.container_summary) ->
                    prerr_endline
                      ("deco:   " ^ dependent.Deco.Podman.id
                      ^
                      if dependent.Deco.Podman.names = [] then ""
                      else
                        " ("
                        ^ String.concat ", " dependent.Deco.Podman.names
                        ^ ")"))
                  dependents
            | Deco.Remove.Planning _ | Deco.Remove.Conflict _
            | Deco.Remove.Runtime _ | Deco.Remove.Podman _ | Deco.Remove.Hook _
              ->
                ());
            List.iter
              (fun mutation ->
                prerr_endline
                  ("deco: Completed command: "
                  ^
                  match mutation with
                  | Deco.Remove.Stop_container -> "container stop."
                  | Deco.Remove.Remove_container -> "container removal."
                  | Deco.Remove.Remove_image -> "image removal."))
              error.Deco.Remove.completed;
            code)

let command =
  let module Arg = Cmdliner.Arg in
  let module Term = Cmdliner.Term in
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:
            "Preview removal without invoking Podman, except to locate a \
             $(b,--project).")
  in
  let keep_image =
    Arg.(
      value & flag
      & info [ "keep-image" ]
          ~doc:"Keep the configured image without inspecting it.")
  in
  let no_hooks =
    Arg.(
      value & flag
      & info [ "no-hooks" ]
          ~doc:
            "Skip the $(b,pre_stop) hook. The configuration then need not be \
             trusted; a warning is printed when it is not.")
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "remove" ~exits:Cli_common.exits
       ~doc:"Remove the owned development container and image.")
    Term.(const execute $ Cli_common.project $ dry_run $ keep_image $ no_hooks)
