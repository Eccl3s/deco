let compatibility ?(selinux_enabled = true) (loaded : Config_loader.t)
    (image : Podman.image) (c : Podman.container) =
  let expected = loaded.effective in
  let failures = ref [] in
  let check b message = if not b then failures := message :: !failures in
  check (c.image_id = image.id) "Container image differs";
  check c.init "Container init is disabled";
  check
    (c.workdir = Option.value ~default:image.workdir expected.container.workdir)
    "Working directory differs";
  (match loaded.identity with
  | User_identity.Image ->
      check
        (c.user = image.user
        && (c.userns = "" || c.userns = "private" || c.userns = "host"))
        "Image user strategy differs";
      check (Ownership.identity c.labels = Ok None) "Unexpected identity label"
  | Keep_id { name; container; _ } ->
      check (c.user = name) "Container user differs";
      check
        (Ownership.identity c.labels
        = Ok (Some { Ownership.uid = container.uid; gid = container.gid }))
        "Identity label differs";
      let prefix = "keep-id:" in
      let actual =
        if String.starts_with ~prefix c.userns then
          String.sub c.userns (String.length prefix)
            (String.length c.userns - String.length prefix)
          |> String.split_on_char ',' |> List.sort compare
        else []
      in
      let wanted =
        List.sort compare
          [
            "uid=" ^ string_of_int container.uid;
            "gid=" ^ string_of_int container.gid;
          ]
      in
      check (actual = wanted)
        "User namespace mapping differs or cannot be verified");
  (match (expected.mounts.workspace, loaded.host_paths.workspace_source) with
  | None, None ->
      check
        (not (List.exists (fun (m : Podman.mount) -> m.kind = "bind") c.mounts))
        "Unexpected bind mount"
  | Some w, Some source -> (
      let matches =
        List.filter
          (fun (m : Podman.mount) -> m.destination = w.target)
          c.mounts
      in
      match matches with
      | [ m ] ->
          check (m.kind = "bind" && m.source = source) "Workspace mount differs";
          let has x = List.mem x m.options in
          check
            (match w.relabel with
            | Config.Shared ->
                has "z" || ((not selinux_enabled) && not (has "Z"))
            | Private -> has "Z" || ((not selinux_enabled) && not (has "z"))
            | No_relabel -> not (has "z" || has "Z"))
            "Mount relabel policy differs or cannot be verified"
      | _ -> check false "Workspace mount missing or duplicated")
  | _ -> check false "Workspace paths disagree");
  match List.rev !failures with
  | [] -> Ok ()
  | xs -> Error (String.concat "; " xs)

type error = Podman of Podman.error | Conflict of string
type environment = { image : Podman.image; container : Podman.container }

let selinux_enabled text =
  try
    let open Yojson.Basic.Util in
    match
      Yojson.Basic.from_string text
      |> member "host" |> member "security" |> member "selinuxEnabled"
    with
    | `Bool enabled -> enabled
    | _ -> true
  with Yojson.Json_error _ | Yojson.Basic.Util.Type_error _ -> true

let availability ?run () = Result.map selinux_enabled (Podman.info ?run ())

let supported_state state =
  List.mem state [ "running"; "created"; "configured"; "exited"; "stopped" ]

let inspect ?(run = fun argv -> Process.run argv) (loaded : Config_loader.t) =
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let wrap = function Ok x -> Ok x | Error e -> Error (Podman e) in
  let own labels =
    match
      Ownership.verify ~project:loaded.effective.project.name
        ~project_root:loaded.project.root labels
    with
    | Ok () -> Ok ()
    | Error _ -> Error (Conflict "Resource ownership differs")
  in
  let* selinux_enabled = wrap (availability ~run ()) in
  let* image =
    wrap
      (Podman.inspect_image ~run
         (loaded.effective.image.name ^ ":" ^ loaded.effective.image.tag))
  in
  let* image =
    match image with
    | Podman.Absent -> Error (Conflict "Configured image is missing")
    | Present i -> Ok i
  in
  let* () = own image.labels in
  let* container =
    wrap (Podman.inspect_container ~run loaded.effective.container.name)
  in
  let* container =
    match container with
    | Podman.Absent ->
        Error (Conflict "Container is missing; run deco assemble")
    | Present c -> Ok c
  in
  let* () = own container.labels in
  let* () =
    match compatibility ~selinux_enabled loaded image container with
    | Ok () -> Ok ()
    | Error e -> Error (Conflict e)
  in
  if supported_state container.state then Ok { image; container }
  else Error (Conflict "Unsupported container state")
