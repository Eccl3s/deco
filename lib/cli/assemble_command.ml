module Arg = Cmdliner.Arg
module Term = Cmdliner.Term
module Cmd = Cmdliner.Cmd

let exits = Cli_common.exits
let project = Cli_common.project

let assemble selection dry_run =
  let open Deco in
  let open Config_loader in
  let open Config.Effective in
  let open Assemble in
  match
    Cli_common.load_trusted_project ~command:"assemble" ~dry_run selection
  with
  | Error code -> code
  | Ok loaded -> (
      if dry_run then (
        match Deco.Assemble_plan.make loaded with
        | Error e ->
            prerr_endline ("deco: " ^ e);
            2
        | Ok plan ->
            print_string (Deco.Assemble_plan.render plan);
            0)
      else
        let image = Config.Effective.image_reference loaded.effective.image in
        let runners = Build_output.runners ~label:"Starting" ~image in
        (* The container is reported as soon as it is running, before the
           output of any hook. *)
        let on_ready outcome =
          runners.Build_output.close true;
          let action =
            if outcome.created then "Created and started"
            else if outcome.started then "Started"
            else "Already running:"
          in
          Printf.printf "%s %s\n%!" action loaded.effective.container.name;
          Ok ()
        in
        let result =
          try
            Deco.Assemble.run ~read_many:runners.Build_output.read_many
              ~execute:runners.Build_output.execute
              ~hook:runners.Build_output.hook ~on_ready loaded
          with e ->
            runners.Build_output.close false;
            raise e
        in
        runners.Build_output.close (Result.is_ok result);
        match result with
        | Ok _ -> 0
        | Error error ->
            let message, code =
              match error.cause with
              | Deco.Assemble.Planning e -> (e, 2)
              | Conflict e -> (e, 4)
              | Runtime e -> (e, 1)
              | Hook failure ->
                  ( Deco.Hook.failure_message failure,
                    Deco.Hook.exit_status failure )
              | Podman (Deco.Podman.Unavailable e) -> (e, 3)
              | Podman
                  ( Deco.Podman.Runtime { operation; message }
                  | Deco.Podman.Invalid_response { operation; message } ) ->
                  (operation ^ ": " ^ message, 1)
            in
            prerr_endline ("deco: " ^ message);
            (match error.cause with
            | Hook _ ->
                prerr_endline
                  ("deco: Container " ^ loaded.effective.container.name
                 ^ " was left running.")
            | Deco.Assemble.Planning _ | Conflict _ | Runtime _ | Podman _ ->
                if error.completed <> [] then
                  prerr_endline
                    ("deco: "
                    ^
                    if List.mem "podman --remote=false create" error.completed
                    then
                      "Container " ^ loaded.effective.container.name
                      ^ " was created but could not be prepared."
                    else
                      "Image build completed; the environment could not be \
                       prepared."));
            code)

let command =
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:
            "Preview the workflow and build/create commands without invoking \
             Podman or writing files. Podman is still queried to locate a \
             $(b,--project).")
  in
  Cmd.v
    (Cmd.info "assemble" ~exits
       ~doc:"Build, create, and start the development container.")
    Term.(const assemble $ project $ dry_run)
