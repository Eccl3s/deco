module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd

let exits =
  [
    Cmd.Exit.info 0 ~doc:"Success, help, or version output.";
    Cmd.Exit.info 1 ~doc:"Runtime or internal failure.";
    Cmd.Exit.info 2 ~doc:"Invalid command usage or project configuration.";
    Cmd.Exit.info 3 ~doc:"Podman is not installed or not usable.";
    Cmd.Exit.info 4 ~doc:"Resource ownership, compatibility, or state conflict.";
    Cmd.Exit.info 5 ~doc:"Project configuration is not trusted.";
  ]

type selection = Discover | Directory of string | Named of string

let project =
  let module Term = Cmdliner.Term in
  let project_dir =
    Arg.(
      value
      & opt (some string) None
      & info Argv.project_dir.Argv.names ~docv:"PATH"
          ~doc:
            "Select a project directory without parent fallback. Cannot be \
             combined with $(b,--project).")
  in
  let project =
    Arg.(
      value
      & opt (some string) None
      & info Argv.project.Argv.names ~docv:"NAME"
          ~doc:
            "Select an assembled project by its configured name, from any \
             directory. The project root is found from the labels of its \
             managed containers, so Podman is required, even with \
             $(b,--dry-run). Cannot be combined with $(b,--project-dir).")
  in
  let select directory name =
    match (directory, name) with
    | Some _, Some _ ->
        Error (`Msg "--project and --project-dir are mutually exclusive")
    | _, Some "" -> Error (`Msg "--project requires a non-empty name")
    | Some directory, None -> Ok (Directory directory)
    | None, Some name -> Ok (Named name)
    | None, None -> Ok Discover
  in
  Term.(term_result ~usage:true (const select $ project_dir $ project))

let report_config_error error =
  Format.eprintf "%a@." Error_report.pp_config_error error;
  Error 2

let load_selected project =
  match project with
  | Error error ->
      prerr_endline ("deco: " ^ Deco.Project.error_to_string error);
      Error 2
  | Ok project -> (
      match Deco.Config_loader.load project with
      | Error error -> report_config_error error
      | Ok loaded -> Ok loaded)

let load_named name =
  let module N = Deco.Named_project in
  let fail code error =
    prerr_endline ("deco: " ^ N.error_to_string error);
    Error code
  in
  match
    N.load
      ~run:(fun argv -> Deco.Process.run ~forward_signals:true argv)
      ~name ()
  with
  | Ok loaded -> Ok loaded
  | Error (N.Config error) -> report_config_error error
  | Error (N.Podman (Deco.Podman.Unavailable _) as error) -> fail 3 error
  | Error
      (N.Podman (Deco.Podman.Runtime _ | Deco.Podman.Invalid_response _) as
       error) ->
      fail 1 error
  | Error
      ((N.No_match _ | N.Ambiguous _ | N.Root _ | N.Name_mismatch _) as error)
    ->
      fail 2 error

let load_project = function
  | Discover -> load_selected (Deco.Project.discover ~start_dir:(Sys.getcwd ()))
  | Directory directory -> load_selected (Deco.Project.select ~directory)
  | Named name -> load_named name

let load_trusted_project ?(no_hooks = false) ~command ~dry_run selection =
  match load_project selection with
  | Error code -> Error code
  | Ok loaded -> (
      match Deco.Trust.check loaded with
      | Error error ->
          prerr_endline ("deco: " ^ Deco.Trust.error_to_string error);
          Error 2
      | Ok status -> (
          List.iter
            (fun warning -> prerr_endline ("deco: " ^ warning))
            status.Deco.Trust.warnings;
          match status.Deco.Trust.state with
          | Deco.Trust.Trusted -> Ok loaded
          | Deco.Trust.Changed | Deco.Trust.Untrusted ->
              if no_hooks then (
                prerr_string (Deco.Trust.no_hooks_warning status);
                Ok loaded)
              else if dry_run then (
                prerr_string (Deco.Trust.dry_run_note ~command);
                Ok loaded)
              else (
                prerr_string (Deco.Trust.failure_message ~command status);
                Error 5)))

let report_hook_failure failure =
  prerr_endline ("deco: " ^ Deco.Hook.failure_message failure);
  Deco.Hook.exit_status failure

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

type format = [ `Human | `Json ]

let format ~doc =
  let open Cmdliner.Arg in
  value
  & opt (enum [ ("human", `Human); ("json", `Json) ]) `Human
  & info Argv.format.Argv.names ~docv:"FORMAT" ~doc
