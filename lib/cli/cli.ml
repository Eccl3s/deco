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

let initialize path template replace dry_run list_templates =
  if list_templates then (
    if path <> None || template <> None || replace || dry_run then (
      prerr_endline "deco: --list-templates must be used alone";
      2)
    else
      let width =
        List.fold_left
          (fun width (t : Deco.Template.t) ->
            max width (String.length t.Deco.Template.name))
          0 Deco.Template.all
      in
      List.iter
        (fun (t : Deco.Template.t) ->
          Format.printf "%-*s  %s@." width t.Deco.Template.name
            t.Deco.Template.description)
        Deco.Template.all;
      0)
  else
    match
      Deco.Init.prepare
        ~path:(Option.value ~default:(Sys.getcwd ()) path)
        ~template:(Option.value ~default:"debian" template)
        ~replace
    with
    | Error error -> (
        prerr_endline ("deco: " ^ Deco.Init.error_to_string error);
        match error with
        | Deco.Init.Filesystem _ -> 1
        | Deco.Init.Invalid _ | Deco.Init.Conflict _ -> 2)
    | Ok plan -> (
        if dry_run then (
          Printf.printf
            "Target: %s\n\
             Template: %s — %s\n\
             Runtime: Podman\n\
             Create .deco/: %b\n"
            plan.Deco.Init.root plan.Deco.Init.template.Deco.Template.name
            plan.Deco.Init.template.Deco.Template.description
            plan.Deco.Init.create_deco;
          List.iter
            (fun (file : Deco.Init.file) ->
              Printf.printf "\n%s %s\n--- contents ---\n%s--- end ---\n"
                (if file.Deco.Init.original = None then "Create" else "Replace")
                file.Deco.Init.path file.Deco.Init.contents)
            plan.Deco.Init.files;
          0)
        else
          match Deco.Init.apply plan with
          | Ok () ->
              List.iter
                (fun (file : Deco.Init.file) ->
                  Printf.printf "Wrote %s\n" file.Deco.Init.path)
                plan.Deco.Init.files;
              0
          | Error error -> (
              prerr_endline ("deco: " ^ Deco.Init.error_to_string error);
              match error with
              | Deco.Init.Filesystem _ -> 1
              | Deco.Init.Invalid _ | Deco.Init.Conflict _ -> 2))

(* Consume option values before interpreting command names or short aliases. *)
let normalize argv =
  let rec aliases = function
    | "--" :: rest -> "--" :: rest
    | (("--project-dir" | "--template" | "-t") as option) :: value :: rest ->
        option :: value :: aliases rest
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
  let init =
    let path = Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH") in
    let template =
      Arg.(
        value & opt (some string) None & info [ "t"; "template" ] ~docv:"NAME")
    in
    let replace =
      Arg.(
        value & flag
        & info [ "R"; "replace" ] ~doc:"Replace existing target files.")
    in
    let dry_run =
      Arg.(
        value & flag & info [ "d"; "dry-run" ] ~doc:"Preview without writing.")
    in
    let listing =
      Arg.(
        value & flag & info [ "list-templates" ] ~doc:"List built-in templates.")
    in
    Cmd.v
      (Cmd.info "init" ~exits
         ~doc:"Initialize a Deco project from a built-in template.")
      Term.(const initialize $ path $ template $ replace $ dry_run $ listing)
  in
  let default =
    Term.(ret (const (fun _ -> `Help (`Plain, None)) $ project_dir))
  in
  Cmd.group ~default
    (Cmd.info "deco" ~version ~exits
       ~doc:"Manage project-local development container configuration.")
    [ validation; init ]

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
