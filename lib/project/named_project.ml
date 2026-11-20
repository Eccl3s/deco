type error =
  | Podman of Podman.error
  | No_match of { name : string; invalid_roots : string list }
  | Ambiguous of { name : string; roots : string list }
  | Root of { name : string; root : string; error : Project.error }
  | Config of Config_loader.error
  | Name_mismatch of {
      name : string;
      root : string;
      config_path : string;
      configured : string;
    }

type candidates = { roots : string list; invalid_roots : string list }

let canonical path = try Unix.realpath path with Unix.Unix_error _ -> path

let candidates ~name containers =
  let recorded =
    List.filter_map
      (fun (container : Podman.listed_container) ->
        match
          ( List.assoc_opt "dev.deco.project" container.labels,
            List.assoc_opt "dev.deco.project-root" container.labels )
        with
        | Some project, Some root when project = name -> Some root
        | _ -> None)
      containers
  in
  (* Deco records canonical absolute roots; anything else is not resolved,
     since a relative path would depend on the working directory. *)
  let valid, invalid =
    List.partition (fun root -> not (Filename.is_relative root)) recorded
  in
  {
    roots = List.sort_uniq String.compare (List.map canonical valid);
    invalid_roots = List.sort_uniq String.compare invalid;
  }

(* The name recorded in the file, read leniently so that a different project
   with an invalid configuration is still recognised as different. *)
let configured_name (project : Project.t) =
  match In_channel.with_open_bin project.config_path In_channel.input_all with
  | contents -> Config.Decode.project_name contents
  | exception Sys_error _ -> None

let load ?run ?(load = fun project -> Config_loader.load project) ~name () =
  match Podman.available ?run () with
  | Error error -> Error (Podman error)
  | Ok () -> (
      match Podman.list_managed_containers ?run () with
      | Error error -> Error (Podman error)
      | Ok containers -> (
          match candidates ~name containers with
          | { roots = []; invalid_roots } ->
              Error (No_match { name; invalid_roots })
          | { roots = _ :: _ :: _ as roots; _ } ->
              Error (Ambiguous { name; roots })
          | { roots = [ root ]; _ } -> (
              match Project.select ~directory:root with
              | Error error -> Error (Root { name; root; error })
              | Ok project -> (
                  let mismatch configured =
                    Error
                      (Name_mismatch
                         {
                           name;
                           root = project.root;
                           config_path = project.config_path;
                           configured;
                         })
                  in
                  match configured_name project with
                  | Some configured when configured <> name ->
                      mismatch configured
                  | Some _ | None -> (
                      match load project with
                      | Error error -> Error (Config error)
                      | Ok loaded ->
                          let configured =
                            loaded.Config_loader.effective
                              .Config.Effective.project
                              .Config.name
                          in
                          if configured = name then Ok loaded
                          else mismatch configured)))))

let error_to_string = function
  | Podman (Podman.Unavailable message) -> message
  | Podman
      ( Podman.Runtime { operation; message }
      | Podman.Invalid_response { operation; message } ) ->
      operation ^ ": " ^ message
  | No_match { name; invalid_roots = [] } ->
      Printf.sprintf
        "No assembled project named %S was found; run deco list to see managed \
         projects"
        name
  | No_match { name; invalid_roots } ->
      Printf.sprintf
        "Project %S is recorded only with invalid project-root labels (%s); \
         use --project-dir to select it"
        name
        (String.concat ", " (List.map (Printf.sprintf "%S") invalid_roots))
  | Ambiguous { name; roots } ->
      Printf.sprintf
        "Project name %S matches several project roots (%s); use --project-dir \
         to select one"
        name (String.concat ", " roots)
  | Root { name; root; error } ->
      Printf.sprintf "Project %S was recorded at %s, which is unusable: %s" name
        root
        (Project.error_to_string error)
  | Config error -> Config_loader.error_to_string error
  | Name_mismatch { name; root; config_path; configured } ->
      Printf.sprintf
        "Project %S was recorded at %s, but %s names project %S; use \
         --project-dir to select it"
        name root config_path configured
