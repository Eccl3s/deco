module Arg = Cmdliner.Arg
module Term = Cmdliner.Term
module Cmd = Cmdliner.Cmd

let exits = Cli_common.exits

(* specs/deco-trust.md: init approves what it wrote, so the new project
   is usable without a review. The written files stay on failure. *)
let trust root =
  let ( let* ) = Result.bind in
  let* project =
    Result.map_error Deco.Project.error_to_string
      (Deco.Project.select ~directory:root)
  in
  let* loaded =
    Result.map_error Deco.Config_loader.error_to_string
      (Deco.Config_loader.load project)
  in
  Result.map_error Deco.Trust.error_to_string
    (Deco.Trust.approve ~deco_version:Generated_version.value
       ~now:(Unix.gettimeofday ()) loaded)

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
             Create .deco/: %b\n\
             Trust: approve the resulting .deco/\n"
            (Deco.Terminal_text.escape plan.Deco.Init.root)
            plan.Deco.Init.template.Deco.Template.name
            plan.Deco.Init.template.Deco.Template.description
            plan.Deco.Init.create_deco;
          List.iter
            (fun (file : Deco.Init.file) ->
              Printf.printf "\n%s %s\n--- contents ---\n%s--- end ---\n"
                (if file.Deco.Init.original = None then "Create" else "Replace")
                (Deco.Terminal_text.escape file.Deco.Init.path)
                file.Deco.Init.contents)
            plan.Deco.Init.files;
          0)
        else
          match Deco.Init.apply plan with
          | Ok () -> (
              let root = Deco.Terminal_text.escape plan.Deco.Init.root in
              match trust plan.Deco.Init.root with
              | Ok () ->
                  Printf.printf
                    "Initialized Deco configuration using template '%s' in %s.\n\
                     Trusted %s\n"
                    plan.Deco.Init.template.Deco.Template.name root root;
                  0
              | Error message ->
                  Printf.eprintf
                    "deco: initialized Deco configuration using template '%s' \
                     in %s, but could not trust it: %s\n\
                     Run 'deco trust' to review and approve it.\n"
                    plan.Deco.Init.template.Deco.Template.name root
                    (Deco.Terminal_text.escape message);
                  1)
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
