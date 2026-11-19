module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd

let exits =
  [
    Cmd.Exit.info 0 ~doc:"Success, help, or version output.";
    Cmd.Exit.info 1 ~doc:"Runtime or internal failure.";
    Cmd.Exit.info 2 ~doc:"Invalid command usage or project configuration.";
    Cmd.Exit.info 3 ~doc:"Podman is not installed or not usable.";
    Cmd.Exit.info 4 ~doc:"Resource ownership, compatibility, or state conflict.";
  ]

let project_dir =
  Arg.(
    value
    & opt (some string) None
    & info Argv.project_dir.Argv.names ~docv:"PATH"
        ~doc:"Select a project directory without parent fallback.")

let load_project project_dir =
  let project =
    match project_dir with
    | Some directory -> Deco.Project.select ~directory
    | None -> Deco.Project.discover ~start_dir:(Sys.getcwd ())
  in
  match project with
  | Error error ->
      prerr_endline ("deco: " ^ Deco.Project.error_to_string error);
      Error 2
  | Ok project -> (
      match Deco.Config_loader.load project with
      | Error error ->
          Format.eprintf "%a@." Error_report.pp_config_error error;
          Error 2
      | Ok loaded -> Ok loaded)

let report_execution_result = function
  | Ok outcome -> (
      match outcome.Deco.Exec.status with
      | Unix.WEXITED code -> code
      | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
          prerr_endline
            "deco: executed process terminated without a normal exit status";
          1)
  | Error error ->
      let message, code =
        match error.Deco.Exec.cause with
        | Deco.Exec.Planning e -> (e, 2)
        | Deco.Exec.Conflict e -> (e, 4)
        | Deco.Exec.Runtime e -> (e, 1)
        | Deco.Exec.Podman (Deco.Podman.Unavailable e) -> (e, 3)
        | Deco.Exec.Podman
            ( Deco.Podman.Runtime { operation; message }
            | Deco.Podman.Invalid_response { operation; message } ) ->
            (operation ^ ": " ^ message, 1)
      in
      prerr_endline ("deco: " ^ message);
      if error.Deco.Exec.started [@warning "-42"] then
        prerr_endline "deco: Container was started and remains available.";
      code
