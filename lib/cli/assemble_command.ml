module Arg = Cmdliner.Arg
module Term = Cmdliner.Term
module Cmd = Cmdliner.Cmd

let exits = Cli_common.exits
let project_dir = Cli_common.project_dir

let assemble project_dir dry_run =
  let open Deco in
  let open Config_loader in
  let open Config.Effective in
  let open Assemble in
  match Cli_common.load_project project_dir with
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
        let image =
          (loaded.effective.image.Config.Effective.name [@warning "-42"]) ^ ":"
          ^ loaded.effective.image.tag
        in
        let status = Build_output.status ~label:"Starting" ~image in
        let result =
          try
            Deco.Assemble.run
              ~execute:(fun output argv ->
                match output with
                | Deco.Process.Inherit ->
                    let result = Build_output.run ~image argv in
                    (match result with
                    | Ok { Deco.Process.status = Unix.WEXITED 0; _ } ->
                        status.Build_output.begin_stage ()
                    | Ok
                        {
                          Deco.Process.status =
                            Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _;
                          _;
                        }
                    | Error _ ->
                        ());
                    result
                | Deco.Process.Capture ->
                    (match argv with
                    | "podman" :: ("create" | "start") :: _ ->
                        status.Build_output.begin_stage ()
                    | _ -> ());
                    Deco.Process.run ~output ~poll:status.Build_output.tick argv)
              loaded
          with e ->
            status.Build_output.finish false;
            raise e
        in
        status.Build_output.finish (Result.is_ok result);
        match result with
        | Ok outcome ->
            let action =
              if outcome.created then "Created and started"
              else if outcome.started then "Started"
              else "Already running:"
            in
            Printf.printf "%s %s\n" action loaded.effective.container.name;
            0
        | Error error ->
            let message, code =
              match error.cause with
              | Deco.Assemble.Planning e -> (e, 2)
              | Conflict e -> (e, 4)
              | Runtime e -> (e, 1)
              | Podman (Deco.Podman.Unavailable e) -> (e, 3)
              | Podman
                  ( Deco.Podman.Runtime { operation; message }
                  | Deco.Podman.Invalid_response { operation; message } ) ->
                  (operation ^ ": " ^ message, 1)
            in
            prerr_endline ("deco: " ^ message);
            if error.completed <> [] then
              prerr_endline
                ("deco: "
                ^
                if List.mem "podman create" error.completed then
                  "Container " ^ loaded.effective.container.name
                  ^ " was created but could not be prepared."
                else
                  "Image build completed; the environment could not be \
                   prepared.");
            code)

let command =
  let dry_run =
    Arg.(
      value & flag
      & info [ "d"; "dry-run" ]
          ~doc:
            "Preview the workflow and build/create commands without invoking \
             Podman or writing files.")
  in
  Cmd.v
    (Cmd.info "assemble" ~exits
       ~doc:"Build, create, and start the development container.")
    Term.(const assemble $ project_dir $ dry_run)
