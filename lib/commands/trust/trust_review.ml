let render ~now (status : Trust.status) (loaded : Config_loader.t) =
  let buffer = Buffer.create 1024 in
  let line fmt =
    Printf.ksprintf
      (fun s ->
        Buffer.add_string buffer s;
        Buffer.add_char buffer '\n')
      fmt
  in
  let safe = Terminal_text.escape in
  let section first title =
    if first then line "%s" title else line "\n%s" title
  in
  let field key value = line "  %-15s %s" (key ^ ":") value in
  let yes_no b = if b then "yes" else "no" in
  let flag flagged note value =
    if flagged then value ^ "  [" ^ note ^ "]" else value
  in
  let within ~dir path =
    path = dir || Trust_digest.relative_to ~dir path <> None
  in
  let effective = loaded.effective in
  let root = status.root in
  section true "Project";
  field "Name" (safe effective.project.name);
  field "Root" (safe root);
  field "Trust state"
    (Trust.state_to_string status.state
    ^
    match (status.state, status.trusted_at) with
    | Trust.Changed, Some time ->
        " (last approved " ^ Timestamp.to_human ~now time ^ ")"
    | (Trust.Trusted | Trust.Changed | Trust.Untrusted), _ -> "");
  if status.changes <> [] then (
    section false "Changed since the last approval";
    List.iter (line "%s") (Trust.render_changes status.changes));
  let build = effective.build in
  let host = loaded.host_paths in
  section false "Build";
  field "Context"
    (flag
       (not (within ~dir:status.deco_dir host.build_context))
       "outside .deco/" (safe host.build_context));
  field "Containerfile" (safe host.containerfile);
  field "Target" (match build.target with Some t -> safe t | None -> "-");
  field "Pull" (yes_no build.pull);
  field "No cache" (yes_no build.no_cache);
  field "Build args"
    (match build.args with
    | [] -> "none"
    | args -> String.concat ", " (List.map (fun (name, _) -> safe name) args));
  section false "Image";
  field "Reference" (safe (Config.Effective.image_reference effective.image));
  section false "Container";
  field "Name" (safe effective.container.name);
  field "Shell" (safe effective.container.shell);
  field "Workdir"
    (match effective.container.workdir with Some w -> safe w | None -> "-");
  field "User mode"
    (match effective.user.mode with
    | Config.Keep_id -> "keep-id"
    | Config.Image -> "image");
  (* Everything here except dropped capabilities can weaken isolation, so it is
     flagged whenever it is set. *)
  let container = effective.container in
  let list note = function
    | [] -> "none"
    | values -> flag true note (String.concat ", " (List.map safe values))
  in
  section false "Security";
  field "Privileged"
    (flag container.privileged "weakens isolation"
       (yes_no container.privileged));
  field "Devices" (list "host devices" container.devices);
  field "Cap add" (list "adds capabilities" container.cap_add);
  field "Cap drop"
    (match container.cap_drop with
    | [] -> "none"
    | values -> String.concat ", " (List.map safe values));
  field "Options" (list "changes confinement" container.security_options);
  (* Names and paths only: values may be secrets, and env file contents are
     not part of the trust digest. *)
  section false "Environment";
  field "Variables"
    (match container.environment with
    | [] -> "none"
    | variables ->
        String.concat ", "
          (List.map safe
             (List.sort_uniq String.compare (List.map fst variables))));
  (match host.env_files with
  | [] -> field "Env files" "none"
  | files ->
      List.iteri
        (fun index file ->
          let value =
            flag (not (within ~dir:root file)) "outside the project" (safe file)
          in
          if index = 0 then field "Env files" value
          else line "  %-15s %s" "" value)
        files);
  section false "Mounts";
  (match (effective.mounts.workspace, host.workspace_source) with
  | Some workspace, Some source ->
      field "Workspace"
        (flag
           (not (within ~dir:root source))
           "outside the project"
           (safe source ^ " -> " ^ safe workspace.target ^ " (read-write)"))
  | Some _, None | None, _ -> field "Workspace" "none");
  section false "Hooks";
  (match Config.Effective.configured_hooks effective.hooks with
  | [] -> line "  none"
  | hooks ->
      List.iter
        (fun (name, command) -> line "  %s = %s" name (safe command))
        hooks);
  section false "Actions";
  (match effective.actions with
  | [] -> line "  none"
  | actions ->
      List.iter
        (fun (name, command) -> line "  %s = %s" (safe name) (safe command))
        actions);
  section false "Planned settings (accepted, not applied by this version)";
  (match Config.Decode.planned_settings loaded.contents with
  | [] -> line "  none"
  | settings ->
      List.iter
        (fun (path, value) ->
          line "  %s = %s" (safe (String.concat "." path)) (safe value))
        settings);
  Buffer.contents buffer
