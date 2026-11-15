type argument = Literal of string | Image_id | Container_id
type step = { condition : string option; command : argument list }
type t = { build : string list; create : argument list; steps : step list }
type error = string

let literals xs = List.map (fun s -> Literal s) xs

let resolve ~image_id ~container_id command =
  List.map
    (function
      | Literal s -> s | Image_id -> image_id | Container_id -> container_id)
    command

let quote s =
  if
    s <> ""
    && String.for_all
         (function
           | 'a' .. 'z'
           | 'A' .. 'Z'
           | '0' .. '9'
           | '_' | '-' | '.' | '/' | ':' | '=' | ',' | '@' | '+' ->
               true
           | _ -> false)
         s
  then s
  else "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let render_command command =
  String.concat " "
    (List.map
       (function
         | Literal s -> quote s
         | Image_id -> "'<image-id>'"
         | Container_id -> "'<container-id>'")
       command)

let render t =
  String.concat "\n"
    (List.map
       (fun step ->
         (match step.condition with None -> "" | Some s -> s ^ ":\n  ")
         ^ render_command step.command)
       t.steps)
  ^ "\n<image-id> and <container-id> are resolved during execution.\n"

let make (loaded : Config_loader.t) =
  let c = loaded.effective and paths = loaded.host_paths in
  let image = c.image.name ^ ":" ^ c.image.tag in
  let label_args labels =
    List.concat_map (fun (k, v) -> [ "--label"; k ^ "=" ^ v ]) labels
  in
  let labels =
    [
      ("dev.deco.managed", "true");
      ("dev.deco.project", c.project.name);
      ("dev.deco.project-root", loaded.project.root);
    ]
  in
  let user_build, user_create, identity =
    match loaded.identity with
    | User_identity.Image -> ([], [], [])
    | Keep_id { name; container; _ } ->
        ( [
            ("USER_NAME", name);
            ("USER_UID", string_of_int container.uid);
            ("USER_GID", string_of_int container.gid);
          ],
          [
            Printf.sprintf "--userns=keep-id:uid=%d,gid=%d" container.uid
              container.gid;
            "--user";
            name;
          ],
          [
            ( "dev.deco.user-identity",
              Printf.sprintf "uid:%d,gid:%d" container.uid container.gid );
          ] )
  in
  let build =
    [
      "podman";
      "build";
      "--file";
      paths.containerfile;
      "--tag";
      image;
      (if c.build.pull then "--pull=newer" else "--pull=missing");
    ]
    @ (if c.build.no_cache then [ "--no-cache" ] else [])
    @ (match c.build.target with
      | None -> []
      | Some target -> [ "--target"; target ])
    @ label_args labels
    @ List.concat_map
        (fun (k, v) -> [ "--build-arg"; k ^ "=" ^ v ])
        (List.sort compare (c.build.args @ user_build))
    @ [ "--"; paths.build_context ]
  in
  let mount =
    match (c.mounts.workspace, paths.workspace_source) with
    | None, None -> Ok []
    | Some w, Some source ->
        if String.contains source ':' || String.contains w.target ':' then
          Error "Workspace mount paths cannot contain colons"
        else
          Ok
            [
              "--volume";
              (source ^ ":" ^ w.target
              ^
              match w.relabel with
              | Config.Shared -> ":z"
              | Private -> ":Z"
              | No_relabel -> "");
            ]
    | _ -> Error "Workspace configuration and resolved paths disagree"
  in
  match mount with
  | Error e -> Error e
  | Ok mount ->
      let create =
        literals
          ([
             "podman";
             "create";
             "--name";
             c.container.name;
             "--init";
             "--pull=never";
           ]
          @ label_args (labels @ identity)
          @ user_create
          @ (match c.container.workdir with
            | None -> []
            | Some w -> [ "--workdir"; w ])
          @ mount @ [ "--" ])
        @ [ Image_id ]
      in
      let step ?condition command = { condition; command } in
      let steps =
        [
          step (literals Podman_command.info);
          step (literals (Podman_command.exists "image" image));
          step ~condition:"If the image exists"
            (literals (Podman_command.inspect "image" image));
          step (literals (Podman_command.exists "container" c.container.name));
          step ~condition:"If the container exists"
            (literals (Podman_command.inspect "container" c.container.name));
          step
            ~condition:
              ("After ownership and compatibility checks pass, if image "
             ^ quote image ^ " is missing")
            (literals build);
          step
            ~condition:
              ("After ownership and compatibility checks pass, if container "
             ^ quote c.container.name ^ " is missing")
            create;
          step
            ~condition:
              ("After ownership and compatibility checks pass, if container "
             ^ quote c.container.name ^ " is new or stopped")
            (literals [ "podman"; "start"; "--" ] @ [ Container_id ]);
        ]
      in
      if
        List.exists
          (fun step ->
            List.exists
              (function Literal s -> String.contains s '\000' | _ -> false)
              step.command)
          steps
      then Error "Command arguments cannot contain NUL bytes"
      else Ok { build; create; steps }
