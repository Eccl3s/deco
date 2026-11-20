module Term = Cmdliner.Term
module Cmd = Cmdliner.Cmd

let exits = Cli_common.exits
let project = Cli_common.project

let validate selection =
  match Cli_common.load_project selection with
  | Error code -> code
  | Ok loaded ->
      Printf.printf "Configuration valid: %s\n"
        loaded.Deco.Config_loader.project.Deco.Project.config_path;
      if loaded.Deco.Config_loader.ignored_paths <> [] then (
        print_endline "Ignored planned settings (not applied in v0.1.0):";
        List.iter
          (fun path -> Printf.printf "  %s\n" (String.concat "." path))
          loaded.Deco.Config_loader.ignored_paths);
      0

let command =
  Cmd.v
    (Cmd.info "validate" ~exits ~doc:"Validate a project's configuration."
       ~man:
         [
           `P
             "Checks configuration, defaults, host paths and identity without \
              Podman. Runtime compatibility, namespace feasibility and image \
              account checks remain deferred; this is not full v1 validation \
              conformance.";
         ])
    Term.(const validate $ project)
