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
    & info [ "project-dir" ] ~docv:"PATH"
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
