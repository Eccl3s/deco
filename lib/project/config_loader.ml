type t = {
  project : Project.t;
  source : Config.t;
  effective : Config.Effective.t;
  host_paths : Host_paths.t;
  identity : User_identity.t;
}

type error =
  | Read_error of { config_path : string; message : string }
  | Decode_errors of { config_path : string; errors : Config.Decode.error list }
  | Validation_errors of {
      config_path : string;
      errors : Config.Validate.error list;
    }
  | Host_path_errors of {
      config_path : string;
      errors : Config.Diagnostic.t list;
    }
  | Identity_errors of {
      config_path : string;
      errors : Config.Diagnostic.t list;
    }

let render_all config_path render errors =
  String.concat "\n"
    (List.map (fun error -> config_path ^ ": " ^ render error) errors)

let error_to_string = function
  | Read_error { config_path; message } -> config_path ^ ": " ^ message
  | Decode_errors { config_path; errors } ->
      render_all config_path Config.Decode.error_to_string errors
  | Validation_errors { config_path; errors } ->
      render_all config_path Config.Validate.error_to_string errors
  | Host_path_errors { config_path; errors } ->
      render_all config_path Config.Diagnostic.to_string errors
  | Identity_errors { config_path; errors } ->
      render_all config_path Config.Diagnostic.to_string errors

let load ?host_ids ?home_dir (project : Project.t) =
  let config_path = project.config_path in
  let contents =
    try Ok (In_channel.with_open_bin config_path In_channel.input_all)
    with Sys_error message ->
      let prefix = config_path ^ ": " in
      let message =
        if String.starts_with ~prefix message then
          String.sub message (String.length prefix)
            (String.length message - String.length prefix)
        else message
      in
      Error (Read_error { config_path; message })
  in
  match contents with
  | Error error -> Error error
  | Ok contents -> (
      match Config.Decode.from_string contents with
      | Error errors -> Error (Decode_errors { config_path; errors })
      | Ok source -> (
          match Config.Resolve.apply source with
          | Error errors -> Error (Validation_errors { config_path; errors })
          | Ok effective -> (
              match Host_paths.resolve ?home_dir ~project effective with
              | Error errors -> Error (Host_path_errors { config_path; errors })
              | Ok host_paths -> (
                  match User_identity.resolve ?host_ids effective.user with
                  | Error errors ->
                      Error (Identity_errors { config_path; errors })
                  | Ok identity ->
                      Ok { project; source; effective; host_paths; identity })))
      )
