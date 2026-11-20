type project = {
  name : string;
  description : string option;
  root : string;
  config : string;
}

type podman = { available : bool; version : string option }

type image = {
  name : string;
  tag : string;
  id : string option;
  exists : bool option;
  created : float option;
  owned : bool option;
}

type container = {
  name : string;
  id : string option;
  exists : bool option;
  state : string option;
  podman_state : string option;
  created : float option;
  owned : bool option;
  compatible : bool option;
  incompatibilities : string list;
}

type runtime = { user_mode : string; workdir : string option; shell : string }

type mount = {
  source : string;
  target : string;
  kind : string;
  readonly : bool;
  relabel : string;
}

type port = { host : int; container : int; protocol : string; bind : string }

type report = {
  project : project;
  podman : podman;
  image : image;
  container : container;
  runtime : runtime;
  mounts : mount list;
  dns : string list;
  ports : port list;
  hooks : string list;
  actions : string list;
}

let state_of_podman = function
  | "running" -> "running"
  | "created" | "configured" | "exited" | "stopped" -> "stopped"
  | "paused" -> "paused"
  | _ -> "unknown"

(* What Podman told us. [None] for a resource means it does not exist. *)
type observed = {
  version : string;
  image : Podman.image option;
  container : Podman.container option;
  incompatibilities : string list option;
}

let ( let* ) = Result.bind

let observe ~run ~probe (loaded : Config_loader.t) =
  let reference =
    loaded.effective.image.name ^ ":" ^ loaded.effective.image.tag
  in
  let container_name = loaded.effective.container.name in
  let owned labels =
    Result.is_ok
      (Ownership.verify ~project:loaded.effective.project.name
         ~project_root:loaded.project.root labels)
  in
  let present = function Podman.Absent -> None | Present x -> Some x in
  let* version = Podman.version ~run () in
  let* image = Podman.inspect_image ~run reference in
  let* container = Podman.inspect_container ~run container_name in
  let image = present image and container = present container in
  let* incompatibilities =
    match (image, container) with
    | Some i, Some c when owned i.labels && owned c.labels ->
        let strict = Container_runtime.incompatibilities loaded i c in
        let relaxed =
          Container_runtime.incompatibilities ~selinux_enabled:false loaded i c
        in
        if strict = relaxed then Ok (Some strict)
        else
          let* enabled =
            Container_runtime.make_selinux_resolver ~run ~probe () ()
          in
          Ok (Some (if enabled then strict else relaxed))
    | _ -> Ok None
  in
  Ok ({ version; image; container; incompatibilities }, owned)

let build (loaded : Config_loader.t) observed =
  let e = loaded.effective in
  let created t = Option.bind t Timestamp.parse in
  let image_workdir =
    match observed with
    | Some ({ image = Some i; _ }, _) when i.Podman.workdir <> "" ->
        Some i.workdir
    | _ -> None
  in
  let image : image =
    let base =
      {
        name = e.image.name;
        tag = e.image.tag;
        id = None;
        exists = None;
        created = None;
        owned = None;
      }
    in
    match observed with
    | None -> base
    | Some ({ image = None; _ }, _) -> { base with exists = Some false }
    | Some ({ image = Some i; _ }, owned) ->
        {
          base with
          id = Some i.id;
          exists = Some true;
          created = created i.created;
          owned = Some (owned i.labels);
        }
  in
  let container : container =
    let base =
      {
        name = e.container.name;
        id = None;
        exists = None;
        state = None;
        podman_state = None;
        created = None;
        owned = None;
        compatible = None;
        incompatibilities = [];
      }
    in
    match observed with
    | None -> base
    | Some ({ container = None; _ }, _) -> { base with exists = Some false }
    | Some ({ container = Some c; incompatibilities; _ }, owned) ->
        {
          base with
          id = Some c.id;
          exists = Some true;
          state = Some (state_of_podman c.state);
          podman_state = Some c.state;
          created = created c.created;
          owned = Some (owned c.labels);
          compatible = Option.map (fun xs -> xs = []) incompatibilities;
          incompatibilities = Option.value ~default:[] incompatibilities;
        }
  in
  let mounts =
    match e.mounts.workspace with
    | None -> []
    | Some w ->
        [
          {
            source =
              Option.value ~default:w.source loaded.host_paths.workspace_source;
            target = w.target;
            kind = "bind";
            readonly = false;
            relabel =
              (match w.relabel with
              | Config.Shared -> "shared"
              | Private -> "private"
              | No_relabel -> "none");
          };
        ]
  in
  {
    project =
      {
        name = e.project.name;
        description = e.project.description;
        root = loaded.project.root;
        config = loaded.project.config_path;
      };
    podman =
      {
        available = Option.is_some observed;
        version = Option.map (fun (o, _) -> o.version) observed;
      };
    image;
    container;
    runtime =
      {
        user_mode =
          (match loaded.identity with
          | User_identity.Image -> "image"
          | Keep_id _ -> "keep-id");
        workdir =
          (match e.container.workdir with
          | Some w -> Some w
          | None -> image_workdir);
        shell = e.container.shell;
      };
    mounts;
    dns = [];
    ports = [];
    hooks = [];
    actions = [];
  }

let collect ?run ?read_many
    ?(probe = fun () -> Container_runtime.local_selinux ())
    (loaded : Config_loader.t) =
  let reference =
    loaded.effective.image.name ^ ":" ^ loaded.effective.image.tag
  in
  let base = Option.value ~default:(fun argv -> Process.run argv) run in
  let result =
    let* run =
      Container_runtime.preflight ?run ?read_many
        [
          Podman_command.version_json;
          Podman_command.inspect "image" reference;
          Podman_command.inspect "container" loaded.effective.container.name;
        ]
    in
    match observe ~run ~probe loaded with
    | Error (Podman.Runtime _ as original) -> (
        (* A failed query may mean Podman stopped being usable. *)
        match Podman.available ~run:base () with
        | Error e -> Error e
        | Ok () -> Error original)
    | other -> other
  in
  match result with
  | Ok observed -> Ok (build loaded (Some observed), None)
  | Error (Podman.Unavailable reason) -> Ok (build loaded None, Some reason)
  | Error e -> Error e

let render_json r =
  let str s = `String s in
  let opt f = function None -> `Null | Some x -> f x in
  let bool b = `Bool b in
  let time t = `String (Timestamp.to_rfc3339 t) in
  let strings xs = `List (List.map str xs) in
  let json =
    `Assoc
      [
        ( "project",
          `Assoc
            [
              ("name", str r.project.name);
              ("description", opt str r.project.description);
              ("root", str r.project.root);
              ("config", str r.project.config);
            ] );
        ( "podman",
          `Assoc
            [
              ("available", bool r.podman.available);
              ("version", opt str r.podman.version);
            ] );
        ( "image",
          `Assoc
            [
              ("name", str r.image.name);
              ("tag", str r.image.tag);
              ("id", opt str r.image.id);
              ("exists", opt bool r.image.exists);
              ("created", opt time r.image.created);
              ("owned", opt bool r.image.owned);
            ] );
        ( "container",
          `Assoc
            [
              ("name", str r.container.name);
              ("id", opt str r.container.id);
              ("exists", opt bool r.container.exists);
              ("state", opt str r.container.state);
              ("podman_state", opt str r.container.podman_state);
              ("created", opt time r.container.created);
              ("owned", opt bool r.container.owned);
              ("compatible", opt bool r.container.compatible);
              ("incompatibilities", strings r.container.incompatibilities);
            ] );
        ( "runtime",
          `Assoc
            [
              ("user_mode", str r.runtime.user_mode);
              ("workdir", opt str r.runtime.workdir);
              ("shell", str r.runtime.shell);
            ] );
        ( "mounts",
          `List
            (List.map
               (fun m ->
                 `Assoc
                   [
                     ("source", str m.source);
                     ("target", str m.target);
                     ("type", str m.kind);
                     ("readonly", bool m.readonly);
                     ("relabel", str m.relabel);
                   ])
               r.mounts) );
        ("dns", strings r.dns);
        ( "ports",
          `List
            (List.map
               (fun (p : port) ->
                 `Assoc
                   [
                     ("host", `Int p.host);
                     ("container", `Int p.container);
                     ("protocol", str p.protocol);
                     ("bind", str p.bind);
                   ])
               r.ports) );
        ("hooks", strings r.hooks);
        ("actions", strings r.actions);
      ]
  in
  Yojson.Basic.pretty_to_string json ^ "\n"
