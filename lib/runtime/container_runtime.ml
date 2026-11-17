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

let local_selinux ?(root = "/sys/fs/selinux") () =
  try
    ignore (Unix.stat root);
    let value =
      In_channel.with_open_bin
        (Filename.concat root "enforce")
        In_channel.input_all
      |> String.trim
    in
    if value = "0" || value = "1" then Some true else None
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Some false
  | Unix.Unix_error _ | Sys_error _ -> None

let make_selinux_resolver ?(run = fun argv -> Process.run argv)
    ?(probe = fun () -> local_selinux ()) () =
  let cached = ref None in
  fun () ->
    match !cached with
    | Some result -> result
    | None ->
        let result =
          match probe () with
          | Some enabled -> Ok enabled
          | None -> availability ~run ()
        in
        cached := Some result;
        result

let check_compatibility ~selinux loaded image container =
  let strict = compatibility loaded image container in
  let relaxed = compatibility ~selinux_enabled:false loaded image container in
  let result =
    if strict = relaxed || Result.is_error relaxed then Ok strict
    else
      match selinux () with
      | Error e -> Error (Podman e)
      | Ok enabled -> Ok (if enabled then strict else relaxed)
  in
  match result with
  | Error e -> Error e
  | Ok (Ok ()) -> Ok ()
  | Ok (Error e) -> Error (Conflict e)

let inspect ?run ?read_many ?(probe = fun () -> local_selinux ()) ?selinux
    ?container_id (loaded : Config_loader.t) =
  let concurrent = Option.is_some read_many || Option.is_none run in
  let injected = run in
  let run = Option.value ~default:(fun argv -> Process.run argv) run in
  let read_many =
    match (read_many, injected) with
    | Some batch, _ -> batch
    | None, Some _ -> List.map run
    | None, None -> fun commands -> Process.run_many commands
  in
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let wrap = function
    | Ok x -> Ok x
    | Error (Podman.Runtime _ as original) -> (
        match Podman.info ~run () with
        | Error e -> Error (Podman e)
        | Ok _ -> Error (Podman original))
    | Error e -> Error (Podman e)
  in
  let own labels =
    match
      Ownership.verify ~project:loaded.effective.project.name
        ~project_root:loaded.project.root labels
    with
    | Ok () -> Ok ()
    | Error _ -> Error (Conflict "Resource ownership differs")
  in
  let* () = wrap (Podman.available ~run ()) in
  let image_command =
    Podman_command.inspect "image"
      (loaded.effective.image.name ^ ":" ^ loaded.effective.image.tag)
  in
  let container_command =
    Podman_command.inspect "container"
      (Option.value ~default:loaded.effective.container.name container_id)
  in
  let responses =
    if concurrent then
      List.combine
        [ image_command; container_command ]
        (read_many [ image_command; container_command ])
    else []
  in
  let run argv =
    match List.assoc_opt argv responses with Some r -> r | None -> run argv
  in
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
    wrap
      (Podman.inspect_container ~run
         (Option.value ~default:loaded.effective.container.name container_id))
  in
  let* container =
    match container with
    | Podman.Absent ->
        Error (Conflict "Container is missing; run deco assemble")
    | Present c -> Ok c
  in
  let* () = own container.labels in
  let selinux =
    match selinux with
    | Some resolve -> resolve
    | None -> make_selinux_resolver ~run ~probe ()
  in
  let* () = check_compatibility ~selinux loaded image container in
  if supported_state container.state then Ok { image; container }
  else Error (Conflict "Unsupported container state")

let inspect_owned_container ?(run = fun argv -> Process.run argv) ?container_id
    (loaded : Config_loader.t) =
  match
    Podman.inspect_container ~run
      (Option.value ~default:loaded.effective.container.name container_id)
  with
  | Error (Podman.Runtime _ as original) -> (
      match Podman.info ~run () with
      | Error e -> Error (Podman e)
      | Ok _ -> Error (Podman original))
  | Error e -> Error (Podman e)
  | Ok Podman.Absent -> Ok Podman.Absent
  | Ok (Podman.Present container) -> (
      match
        Ownership.verify ~project:loaded.effective.project.name
          ~project_root:loaded.project.root container.labels
      with
      | Ok () -> Ok (Podman.Present container)
      | Error _ -> Error (Conflict "Resource ownership differs"))
