open Config_types

type error = Diagnostic.t = { path : string list; message : string }

let ascii_letter = function 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false
let digit = function '0' .. '9' -> true | _ -> false
let name_char c = ascii_letter c || digit c || List.mem c [ '.'; '_'; '-' ]
let error_to_string = Diagnostic.to_string
let valid_id n = n >= 0 && Int64.of_int n <= 4294967294L

(* [A-Za-z_][A-Za-z0-9_]*, the form of build argument and environment variable
   names. *)
let variable_name key =
  key <> ""
  && (ascii_letter key.[0] || key.[0] = '_')
  && String.for_all (fun c -> ascii_letter c || digit c || c = '_') key

let check (config : Config_types.t) =
  let errors = ref [] in
  let error path message = errors := { path; message } :: !errors in
  let optional path check = Option.iter (check path) in
  let nonblank path value =
    if String.trim value = "" then (
      error path "Must not be blank";
      false)
    else true
  in
  let valid_name value =
    let n = String.length value in
    n >= 1 && n <= 128
    && (ascii_letter value.[0] || digit value.[0])
    && String.for_all name_char value
  in
  let name path value =
    if not (valid_name value) then
      error path
        "Expected 1-128 ASCII name characters, starting with a letter or digit"
  in
  let container_path path value =
    if nonblank path value then
      if value.[0] <> '/' then error path "Expected an absolute container path"
      else if
        List.exists
          (fun part -> part = "." || part = "..")
          (String.split_on_char '/' value)
      then error path "Container paths must not contain . or .. components"
  in
  name [ "project"; "name" ] config.project.name;
  let explicit_image_name =
    Option.bind config.image (fun image -> image.name)
  in
  let check_image path check value =
    match check value with Ok () -> () | Error message -> error path message
  in
  (match explicit_image_name with
  | Some value ->
      check_image [ "image"; "name" ] Image_reference.check_name value
  | None when valid_name config.project.name -> (
      let derived = config.project.name ^ "-dev-image" in
      match Image_reference.check_name derived with
      | Ok () -> ()
      | Error message ->
          error [ "image"; "name" ]
            (Printf.sprintf
               "Derived image name %S is invalid: %s; set an explicit valid \
                image.name"
               derived message))
  | None -> ());
  Option.iter
    (fun image ->
      optional [ "image"; "tag" ]
        (fun path value -> check_image path Image_reference.check_tag value)
        image.tag)
    config.image;
  let explicit_container_name =
    Option.bind config.container (fun container -> container.name)
  in
  if
    explicit_container_name = None
    && valid_name config.project.name
    && not (valid_name (config.project.name ^ "-dev-container"))
  then
    error [ "container"; "name" ]
      "Derived container name exceeds 128 characters; set an explicit shorter \
       container.name";

  Option.iter
    (fun (container : container) ->
      optional [ "container"; "name" ] name container.name;
      optional [ "container"; "workdir" ] container_path container.workdir;
      optional [ "container"; "shell" ]
        (fun path value ->
          if nonblank path value && String.contains value '/' then
            container_path path value)
        container.shell;
      let each key values check =
        List.iteri
          (fun index value ->
            check [ "container"; Printf.sprintf "%s[%d]" key index ] value)
          (Option.value ~default:[] values)
      in
      let absolute s = s <> "" && s.[0] = '/' in
      let no_nul path value =
        if String.contains value '\000' then (
          error path "Must not contain NUL bytes";
          false)
        else true
      in
      each "devices" container.devices (fun path value ->
          if no_nul path value then
            let permissions s =
              s <> ""
              && String.for_all (fun c -> List.mem c [ 'r'; 'w'; 'm' ]) s
              && List.length
                   (List.sort_uniq Char.compare (List.of_seq (String.to_seq s)))
                 = String.length s
            in
            match String.split_on_char ':' value with
            | host :: _ when not (absolute host) ->
                error path "Expected an absolute host device path"
            | [ _ ] -> ()
            | _ :: target :: _ when not (absolute target) ->
                error path "Expected an absolute container device path"
            | [ _; _ ] -> ()
            | [ _; _; perms ] ->
                if not (permissions perms) then
                  error path
                    "Device permissions may contain only r, w and m, each at \
                     most once"
            | _ ->
                error path
                  "Expected HOST_PATH, HOST_PATH:CONTAINER_PATH or \
                   HOST_PATH:CONTAINER_PATH:PERMISSIONS");
      let capability path value =
        if
          value = ""
          || not
               (String.for_all
                  (fun c -> ascii_letter c || digit c || c = '_' || c = '-')
                  value)
        then
          error path
            "Expected a capability name of ASCII letters, digits, _ or -"
      in
      each "cap_add" container.cap_add capability;
      each "cap_drop" container.cap_drop capability;
      each "security_options" container.security_options (fun path value ->
          if value = "" then error path "Must not be empty"
          else ignore (no_nul path value));
      each "env_files" container.env_files (fun path value ->
          if nonblank path value then ignore (no_nul path value));
      List.iter
        (fun (key, value) ->
          let path = [ "container"; "environment"; key ] in
          if not (variable_name key) then
            error path
              "Expected an environment variable name matching \
               [A-Za-z_][A-Za-z0-9_]*"
          else ignore (no_nul path value))
        (Option.value ~default:[] container.environment))
    config.container;
  Option.iter
    (fun (mounts : mounts) ->
      Option.iter
        (fun (workspace : workspace) ->
          container_path [ "mounts"; "workspace"; "target" ] workspace.target)
        mounts.workspace)
    config.mounts;
  Option.iter
    (fun (build : build) ->
      List.iter
        (fun (key, _) ->
          let path = [ "build"; "args"; key ] in
          if not (variable_name key) then
            error path
              "Expected a build argument name matching [A-Za-z_][A-Za-z0-9_]*"
          else if List.mem key [ "USER_NAME"; "USER_UID"; "USER_GID" ] then
            error path "Build argument is reserved for Deco user configuration")
        build.args)
    config.build;
  Option.iter
    (fun (user : user) ->
      let mode = Option.value ~default:Image user.mode in
      List.iter
        (fun (key, value) ->
          match value with
          | None -> ()
          | Some _ when mode = Image ->
              error [ "user"; key ]
                "Must be omitted in image mode (a restriction beyond the v1 \
                 specification)"
          | Some (Id n) when not (valid_id n) ->
              error [ "user"; key ] "Expected an ID in 0-4294967294"
          | Some _ -> ())
        [ ("uid", user.uid); ("gid", user.gid) ];
      match (Option.value ~default:Image user.mode, user.name) with
      | Keep_id, None -> error [ "user"; "name" ] "Required for keep-id mode"
      | Keep_id, Some value -> ignore (nonblank [ "user"; "name" ] value)
      | Image, Some _ ->
          error [ "user"; "name" ] "Must be omitted in image mode"
      | Image, None -> ())
    config.user;
  Option.iter
    (fun hooks ->
      List.iter
        (fun (key, value) ->
          if String.contains value '\000' then
            error [ "hooks"; key ] "Must not contain NUL bytes")
        (Effective.configured_hooks hooks))
    config.hooks;
  List.iter
    (fun (name, command) ->
      let path = [ "actions"; name ] in
      if
        name = ""
        || (not (ascii_letter name.[0]))
        || not
             (String.for_all
                (fun c -> ascii_letter c || digit c || c = '_' || c = '-')
                name)
      then error path "Expected an action name matching [A-Za-z][A-Za-z0-9_-]*"
      else if nonblank path command && String.contains command '\000' then
        error path "Must not contain NUL bytes")
    (Option.value config.actions ~default:[]);
  match !errors with
  | [] -> Ok ()
  | errors -> Error (List.sort Diagnostic.compare errors)
