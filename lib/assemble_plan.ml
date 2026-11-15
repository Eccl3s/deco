type operation =
  | Availability
  | Image_exists
  | Image_inspect
  | Container_exists
  | Container_inspect
  | Build
  | Built_exists
  | Built_inspect
  | Create
  | Created_exists
  | Created_inspect
  | Start
  | Started_exists
  | Started_inspect

type argument = Literal of string | Image_id | Container_id

type step = {
  operation : operation;
  condition : string option;
  command : argument list;
}

type t = {
  image_name : string;
  container_name : string;
  build : string list;
  create : argument list;
  steps : step list;
}

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

let render_multiline command =
  let paired =
    [
      "--file";
      "--tag";
      "--target";
      "--label";
      "--build-arg";
      "--name";
      "--user";
      "--workdir";
      "--volume";
      "--";
    ]
  in
  let rec groups = function
    | [] -> []
    | (Literal flag as arg) :: value :: rest when List.mem flag paired ->
        render_command [ arg; value ] :: groups rest
    | arg :: rest -> render_command [ arg ] :: groups rest
  in
  match command with
  | executable :: subcommand :: rest -> (
      "    "
      ^ render_command [ executable; subcommand ]
      ^
      match groups rest with
      | [] -> ""
      | xs -> " \\\n      " ^ String.concat " \\\n      " xs)
  | _ -> "    " ^ render_command command

let render t =
  let command operation =
    (List.find (fun step -> step.operation = operation) t.steps).command
  in
  "Assemble preview\nNo commands will be run.\n\n"
  ^ "1. Check for an existing Deco project environment.\n\n" ^ "2. Build image "
  ^ t.image_name ^ " if missing.\n\n"
  ^ render_multiline (command Build)
  ^ "\n\n" ^ "3. Create container " ^ t.container_name ^ " if missing.\n\n"
  ^ render_multiline (command Create)
  ^ "\n\n" ^ "4. Start " ^ t.container_name ^ " if needed.\n\n"
  ^ "<image-id> is resolved when assembling the environment.\n"

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
      let roles =
        [
          Availability;
          Image_exists;
          Image_inspect;
          Container_exists;
          Container_inspect;
          Build;
          Built_exists;
          Built_inspect;
          Create;
          Created_exists;
          Created_inspect;
          Start;
          Started_exists;
          Started_inspect;
        ]
      in
      let step ?condition command =
        { operation = Availability; condition; command }
      in
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
          step ~condition:"After building the missing image"
            (literals (Podman_command.exists "image" image));
          step ~condition:"After building the missing image"
            (literals (Podman_command.inspect "image" image));
          step
            ~condition:
              ("After ownership and compatibility checks pass, if container "
             ^ quote c.container.name ^ " is missing")
            create;
          step ~condition:"After creating the missing container"
            (literals [ "podman"; "container"; "exists"; "--" ]
            @ [ Container_id ]);
          step ~condition:"After creating the missing container"
            (literals [ "podman"; "container"; "inspect"; "--" ]
            @ [ Container_id ]);
          step
            ~condition:
              ("After ownership and compatibility checks pass, if container "
             ^ quote c.container.name ^ " is new or stopped")
            (literals [ "podman"; "start"; "--" ] @ [ Container_id ]);
          step ~condition:"After starting the container"
            (literals [ "podman"; "container"; "exists"; "--" ]
            @ [ Container_id ]);
          step ~condition:"After starting the container"
            (literals [ "podman"; "container"; "inspect"; "--" ]
            @ [ Container_id ]);
        ]
      in
      assert (List.length roles = List.length steps);
      let steps =
        List.map2 (fun operation step -> { step with operation }) roles steps
      in
      if
        List.exists
          (fun step ->
            List.exists
              (function Literal s -> String.contains s '\000' | _ -> false)
              step.command)
          steps
      then Error "Command arguments cannot contain NUL bytes"
      else
        Ok
          {
            image_name = image;
            container_name = c.container.name;
            build;
            create;
            steps;
          }
