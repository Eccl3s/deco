let version = Generated_version.value

let validate project_dir =
  let project =
    match project_dir with
    | Some directory -> Deco.Project.select ~directory
    | None -> Deco.Project.discover ~start_dir:(Sys.getcwd ())
  in
  match project with
  | Error error ->
      prerr_endline ("deco: " ^ Deco.Project.error_to_string error);
      2
  | Ok project -> (
      match Deco.Config_loader.load project with
      | Error error ->
          Format.eprintf "%a@." Error_report.pp_config_error error;
          2
      | Ok _ ->
          Printf.printf "Configuration valid: %s\n"
            project.Deco.Project.config_path;
          0)

(* Consume option values before interpreting command names or short aliases. *)
let normalize argv =
  let rec aliases = function
    | "--" :: rest -> "--" :: rest
    | "--project-dir" :: value :: rest ->
        "--project-dir" :: value :: aliases rest
    | "-h" :: rest -> "--help" :: aliases rest
    | "-V" :: rest -> "--version" :: aliases rest
    | value :: rest -> value :: aliases rest
    | [] -> []
  in
  let rec reorder prefix = function
    | "--project-dir" :: value :: rest ->
        reorder (prefix @ [ "--project-dir"; value ]) rest
    | value :: rest when String.starts_with ~prefix:"--project-dir=" value ->
        reorder (prefix @ [ value ]) rest
    | (("--help" | "--version") as value) :: rest ->
        reorder (prefix @ [ value ]) rest
    | value :: rest when String.starts_with ~prefix:"--help=" value ->
        reorder (prefix @ [ value ]) rest
    | command :: rest when command <> "" && command.[0] <> '-' ->
        (command :: prefix) @ rest
    | rest -> prefix @ rest
  in
  match Array.to_list argv with
  | [] -> argv
  | executable :: args -> Array.of_list (executable :: reorder [] (aliases args))

let command =
  let module Arg = Cmdliner.Arg in
  let module Term = Cmdliner.Term in
  let module Cmd = Cmdliner.Cmd in
  let exits =
    [
      Cmd.Exit.info 0 ~doc:"Success, help, or version output.";
      Cmd.Exit.info 1 ~doc:"Runtime or internal failure.";
      Cmd.Exit.info 2 ~doc:"Invalid command usage or project configuration.";
    ]
  in
  let project_dir =
    Arg.(
      value
      & opt (some string) None
      & info [ "project-dir" ] ~docv:"PATH"
          ~doc:"Select a project directory without parent fallback.")
  in
  let validation =
    Cmd.v
      (Cmd.info "validate" ~exits ~doc:"Validate a project's configuration."
         ~man:
           [
             `P
               "Checks configuration, defaults, host paths and identity \
                without Podman. Runtime compatibility, namespace feasibility \
                and image account checks remain deferred; this is not full v1 \
                validation conformance.";
           ])
      Term.(const validate $ project_dir)
  in
  let default =
    Term.(ret (const (fun _ -> `Help (`Plain, None)) $ project_dir))
  in
  Cmd.group ~default
    (Cmd.info "deco" ~version ~exits
       ~doc:"Manage project-local development container configuration.")
    [ validation ]

let run () =
  (* Plain output also keeps parser/help diagnostics free of terminal styling. *)
  Unix.putenv "NO_COLOR" "1";
  Unix.putenv "TERM" "dumb";
  let status =
    try
      match
        Cmdliner.Cmd.eval_value ~catch:false ~argv:(normalize Sys.argv) command
      with
      | Ok (`Ok status) -> status
      | Ok (`Help | `Version) -> 0
      | Error (`Parse | `Term) -> 2
      | Error `Exn -> 1
    with _ ->
      prerr_endline "deco: internal error";
      1
  in
  status
