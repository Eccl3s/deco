module Arg = Cmdliner.Arg
module Term = Cmdliner.Term
module Cmd = Cmdliner.Cmd

let exits = Cli_common.exits

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
              Printf.printf
                "Initialized Deco configuration using template '%s' in %s.\n"
                plan.Deco.Init.template.Deco.Template.name plan.Deco.Init.root;
              0
          | Error error -> (
              prerr_endline ("deco: " ^ Deco.Init.error_to_string error);
              match error with
              | Deco.Init.Filesystem _ -> 1
              | Deco.Init.Invalid _ | Deco.Init.Conflict _ -> 2))

let command =
  let path = Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH") in
  let template =
    Arg.(
      value
      & opt (some string) None
      & info Argv.template.Argv.names ~docv:"NAME")
  in
  let replace =
    Arg.(
      value & flag
      & info [ "R"; "replace" ] ~doc:"Replace existing target files.")
  in
  let dry_run =
    Arg.(value & flag & info [ "d"; "dry-run" ] ~doc:"Preview without writing.")
  in
  let listing =
    Arg.(
      value & flag & info [ "list-templates" ] ~doc:"List built-in templates.")
  in
  Cmd.v
    (Cmd.info "init" ~exits
       ~doc:"Initialize a Deco project from a built-in template.")
    Term.(const initialize $ path $ template $ replace $ dry_run $ listing)
