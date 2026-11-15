open Config_types

type error = Diagnostic.t = { path : string list; message : string }

let ascii_letter = function 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false
let digit = function '0' .. '9' -> true | _ -> false
let name_char c = ascii_letter c || digit c || List.mem c [ '.'; '_'; '-' ]
let error_to_string = Diagnostic.to_string

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
        container.shell)
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
          if
            key = ""
            || (not (ascii_letter key.[0] || key.[0] = '_'))
            || not
                 (String.for_all
                    (fun c -> ascii_letter c || digit c || c = '_')
                    key)
          then
            error path
              "Expected a build argument name matching [A-Za-z_][A-Za-z0-9_]*"
          else if List.mem key [ "USER_NAME"; "USER_UID"; "USER_GID" ] then
            error path "Build argument is reserved for Deco user configuration")
        build.args)
    config.build;
  Option.iter
    (fun (user : user) ->
      match (Option.value ~default:Image user.mode, user.name) with
      | Keep_id, None -> error [ "user"; "name" ] "Required for keep-id mode"
      | Keep_id, Some value -> ignore (nonblank [ "user"; "name" ] value)
      | Image, Some _ ->
          error [ "user"; "name" ] "Must be omitted in image mode"
      | Image, None -> ())
    config.user;
  match !errors with
  | [] -> Ok ()
  | errors -> Error (List.sort Diagnostic.compare errors)
