open Deco

let get = function Ok x -> x | Error e -> failwith e

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname = 'example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      source;
      effective;
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [];
          protected = [];
          deco_protection = Not_applicable;
          git_protection = Not_applicable;
        };
      identity = User_identity.Image;
    }
  in
  let plan = get (Assemble_plan.make loaded) in
  assert (List.length plan.steps = 9);
  assert (
    (List.hd plan.steps).command
    = List.map (fun s -> Assemble_plan.Literal s) Podman_command.version);
  assert (List.mem "--pull=missing" plan.build);
  let create =
    Assemble_plan.resolve ~image_id:"sha256:abc" ~container_id:"cid" plan.create
  in
  assert (List.mem "--init" create && List.mem "--pull=never" create);
  assert (List.hd (List.rev create) = "sha256:abc");
  assert (not (List.mem "--user" create));
  let input = "a 'quoted'; $(echo bad)\n" in
  let rendered = Assemble_plan.render_command [ Literal input ] in
  let r =
    get
      (Result.map_error
         (fun e -> e.Process.message)
         (Process.run [ "/bin/sh"; "-c"; "printf %s " ^ rendered ]))
  in
  assert (r.stdout = input);
  let loaded =
    {
      loaded with
      identity =
        Keep_id
          {
            name = "dev";
            host = { uid = 42; gid = 43 };
            container = { uid = 1000; gid = 1001 };
          };
    }
  in
  let plan = get (Assemble_plan.make loaded) in
  assert (List.mem "USER_UID=1000" plan.build);
  assert (
    List.mem (Assemble_plan.Literal "--userns=keep-id:uid=1000,gid=1001")
      plan.create);
  List.iter
    (fun (relabel, suffix) ->
      let effective =
        {
          effective with
          mounts =
            {
              workspace =
                Some
                  {
                    source = ".";
                    target = "/workspace";
                    relabel;
                    protect_git = true;
                  };
            };
        }
      in
      let loaded =
        {
          loaded with
          effective;
          host_paths =
            {
              loaded.host_paths with
              workspace_source = Some "/project with spaces";
            };
        }
      in
      let p = get (Assemble_plan.make loaded) in
      assert (
        List.mem
          (Assemble_plan.Literal ("/project with spaces:/workspace" ^ suffix))
          p.create);
      assert (
        Result.is_error
          (Assemble_plan.make
             {
               loaded with
               host_paths =
                 { loaded.host_paths with workspace_source = Some "/bad:path" };
             })))
    [ (Config.Shared, ":z"); (Private, ":Z"); (No_relabel, "") ];
  assert (
    Result.is_error
      (Assemble_plan.make
         {
           loaded with
           effective =
             {
               effective with
               build =
                 { effective.build with args = [ ("VALUE", "bad\000value") ] };
             };
         }));
  let custom =
    {
      loaded with
      effective =
        {
          effective with
          build =
            {
              effective.build with
              pull = true;
              target = Some "development";
              no_cache = true;
              args = [ ("VALUE", "hello world") ];
            };
          container = { effective.container with workdir = Some "/work" };
        };
    }
  in
  let custom_plan = get (Assemble_plan.make custom) in
  let has_pair key value xs =
    let rec loop = function
      | a :: b :: _ when a = key && b = value -> true
      | _ :: rest -> loop rest
      | [] -> false
    in
    loop xs
  in
  assert (List.mem "--pull=newer" custom_plan.build);
  assert (List.mem "--no-cache" custom_plan.build);
  assert (has_pair "--target" "development" custom_plan.build);
  let create =
    Assemble_plan.resolve ~image_id:"iid" ~container_id:"cid" custom_plan.create
  in
  assert (has_pair "--workdir" "/work" create);
  List.iter
    (fun label ->
      assert (has_pair "--label" label custom_plan.build);
      assert (has_pair "--label" label create))
    [
      "dev.deco.managed=true";
      "dev.deco.project=example";
      "dev.deco.project-root=/project";
    ];
  assert (has_pair "--label" "dev.deco.user-identity=uid:1000,gid:1001" create);
  assert (
    not
      (has_pair "--label" "dev.deco.user-identity=uid:1000,gid:1001"
         custom_plan.build));
  assert (
    Assemble_plan.make
      {
        loaded with
        host_paths =
          { loaded.host_paths with workspace_source = Some "/unexpected" };
      }
    = Error "Workspace configuration and resolved paths disagree");
  assert (
    Assemble_plan.make
      {
        loaded with
        effective =
          {
            effective with
            mounts =
              {
                workspace =
                  Some
                    {
                      source = ".";
                      target = "/workspace";
                      relabel = Config.No_relabel;
                      protect_git = true;
                    };
              };
          };
      }
    = Error "Workspace configuration and resolved paths disagree");
  assert (
    Assemble_plan.render_multiline
      [
        Literal "podman";
        Literal "--remote=false";
        Literal "build";
        Literal "--file";
        Literal "/some path/Containerfile";
        Literal "--no-cache";
        Literal "--";
        Literal "/context";
      ]
    = String.concat
        (" " ^ String.make 1 (Char.chr 92) ^ "\n      ")
        [
          "    podman --remote=false build";
          "--file '/some path/Containerfile'";
          "--no-cache";
          "-- /context";
        ]);
  let rendered = Assemble_plan.render custom_plan in
  let contains text =
    let rec loop i =
      i + String.length text <= String.length rendered
      && (String.sub rendered i (String.length text) = text || loop (i + 1))
    in
    loop 0
  in
  List.iter
    (fun text -> assert (contains text))
    [
      "Assemble preview\nNo commands will be run.\n\n";
      "1. Check for an existing Deco project environment.";
      "2. Build image example-dev-image:latest if missing.";
      "3. Create container example-dev-container if missing.";
      "4. Start example-dev-container if needed.";
      "'<image-id>'";
      "'VALUE=hello world'";
      "<image-id> is resolved when assembling the environment.";
    ];
  List.iter
    (fun text -> assert (not (contains text)))
    [
      "podman --remote=false info";
      "podman --remote=false image exists";
      "podman --remote=false image inspect";
      "podman --remote=false container exists";
      "podman --remote=false container inspect";
      "podman --remote=false start";
      "<container-id>";
    ];
  List.iter
    (fun value ->
      let command =
        Assemble_plan.render_multiline
          [ Literal "printf"; Literal "%s"; Literal value ]
      in
      let r =
        get
          (Result.map_error
             (fun e -> e.Process.message)
             (Process.run [ "/bin/sh"; "-c"; command ]))
      in
      assert (r.status = Unix.WEXITED 0 && r.stdout = value))
    [ ""; "spaces and 'quotes'"; "$(echo bad); &"; "line one\nline two" ];
  assert (
    Assemble_plan.render custom_plan
    = Assemble_plan.render (get (Assemble_plan.make custom)))

(* Configured hooks follow the start in execution order; without hooks the
   preview ends at the start. *)
let () =
  let load text =
    let source = Result.get_ok (Config.Decode.from_string text) in
    ({
       ignored_paths = [];
       contents = "";
       project =
         { root = "/project"; config_path = "/project/.deco/config.toml" };
       source;
       effective = Result.get_ok (Config.Resolve.apply source);
       host_paths =
         {
           build_context = "/project/.deco/build";
           containerfile = "/project/.deco/build/Containerfile";
           workspace_source = None;
           env_files = [];
           protected = [];
           deco_protection = Not_applicable;
           git_protection = Not_applicable;
         };
       identity = User_identity.Image;
     }
      : Config_loader.t)
  in
  let render text =
    Assemble_plan.render (get (Assemble_plan.make (load text)))
  in
  let contains rendered text =
    let rec loop i =
      i + String.length text <= String.length rendered
      && (String.sub rendered i (String.length text) = text || loop (i + 1))
    in
    loop 0
  in
  let plain = render "project.name='example'\n" in
  assert (not (contains plain "hook"));
  assert (
    contains plain
      "4. Start example-dev-container if needed.\n\n<image-id> is resolved");
  let both =
    render
      "project.name='example'\n\
       hooks={post_create='make setup',post_start='echo ready'}\n"
  in
  assert (
    contains both
      "4. Start example-dev-container if needed.\n\n\
       5. If the container is new or had never been started, run the \
       post_create hook:\n\
      \    podman --remote=false exec \\\n");
  assert (
    contains both
      "6. If the container was created or started, run the post_start hook:\n");
  assert (contains both "'make setup'" && contains both "'echo ready'");
  assert (contains both "An already running container runs no hook.");
  let only_start = render "project.name='example'\nhooks.post_start='x'\n" in
  assert (
    contains only_start
      "5. If the container was created or started, run the post_start hook:\n");
  assert (not (contains only_start "post_create"))

(* Containers record the configured shell so hooks are not run with a shell
   the container may not have. *)
let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "project.name='example'\ncontainer.shell='/bin/zsh'\n")
  in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [];
          protected = [];
          deco_protection = Not_applicable;
          git_protection = Not_applicable;
        };
      identity = User_identity.Image;
    }
  in
  let plan = get (Assemble_plan.make loaded) in
  let rec pairs = function
    | Command_plan.Literal "--label" :: Command_plan.Literal value :: rest ->
        value :: pairs rest
    | _ :: rest -> pairs rest
    | [] -> []
  in
  assert (List.mem "dev.deco.shell=/bin/zsh" (pairs plan.create));
  (* The image is not labelled with the shell. *)
  assert (
    not (List.exists (String.starts_with ~prefix:"dev.deco.shell") plan.build));
  (* The container records its create-settings digest; the image does not. *)
  assert (
    List.mem
      ("dev.deco.create-digest=" ^ Create_settings.of_loaded loaded)
      (pairs plan.create));
  assert (
    not
      (List.exists
         (String.starts_with ~prefix:"dev.deco.create-digest")
         plan.build))

(* Container security options become create flags in configured order, after
   the user flags and before the workdir; defaults add nothing. *)
let () =
  let loaded text : Config_loader.t =
    let source =
      Result.get_ok
        (Config.Decode.from_string ("project.name='example'\n" ^ text))
    in
    {
      ignored_paths = [];
      contents = "";
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files = [];
          protected = [];
          deco_protection = Not_applicable;
          git_protection = Not_applicable;
        };
      identity = User_identity.Image;
    }
  in
  let literals command =
    List.filter_map
      (function Command_plan.Literal s -> Some s | _ -> None)
      command
  in
  let security =
    [ "--privileged"; "--device"; "--cap-add"; "--cap-drop"; "--security-opt" ]
  in
  let flagged argv =
    List.filter
      (fun arg ->
        List.exists
          (fun flag ->
            arg = flag || String.starts_with ~prefix:(flag ^ "=") arg)
          security)
      argv
  in
  let plain = get (Assemble_plan.make (loaded "")) in
  assert (flagged (literals plain.create) = []);
  let secured =
    loaded
      "container.workdir='/work'\n\
       container.privileged=true\n\
       container.devices=['/dev/fuse','/dev/a:/dev/b:rw']\n\
       container.cap_add=['SYS_ADMIN','MKNOD']\n\
       container.cap_drop=['-weird','ALL']\n\
       container.security_options=['label=disable']"
  in
  let plan = get (Assemble_plan.make secured) in
  let create = literals plan.create in
  assert (
    flagged create
    = [
        "--privileged";
        "--device=/dev/fuse";
        "--device=/dev/a:/dev/b:rw";
        "--cap-add=SYS_ADMIN";
        "--cap-add=MKNOD";
        "--cap-drop=-weird";
        "--cap-drop=ALL";
        "--security-opt=label=disable";
      ]);
  let index x =
    let rec go i = function
      | [] -> raise Not_found
      | y :: rest -> if y = x then i else go (i + 1) rest
    in
    go 0 create
  in
  assert (index "--security-opt=label=disable" < index "--workdir");
  assert (flagged plan.build = []);
  (* The digest label records the settings. *)
  assert (
    List.mem
      ("dev.deco.create-digest=" ^ Create_settings.of_loaded secured)
      create);
  assert (Create_settings.of_loaded secured <> Create_settings.digest []);
  (* With cap_add, the create step names the capabilities label check. *)
  let contains s sub =
    let n = String.length sub in
    let rec go i =
      i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
    in
    go 0
  in
  assert (
    contains
      (Assemble_plan.render plan)
      "Create container example-dev-container if missing, after checking that \
       the image's io.containers.capabilities label, if it has one, allows \
       every --cap-add entry.\n");
  assert (
    not (contains (Assemble_plan.render plain) "io.containers.capabilities"));
  (* The dry-run preview shows the flags. *)
  let preview = Assemble_plan.render plan in
  List.iter
    (fun flag ->
      let contains s sub =
        let n = String.length sub in
        let rec go i =
          i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
        in
        go 0
      in
      assert (contains preview flag))
    (flagged create)

(* Env files and variables become create flags after the security options and
   before the workdir, in configured order. Values reach Podman but never the
   preview. *)
let () =
  let loaded text env_files : Config_loader.t =
    let source =
      Result.get_ok
        (Config.Decode.from_string ("project.name='example'\n" ^ text))
    in
    {
      ignored_paths = [];
      contents = "";
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
          env_files;
          protected = [];
          deco_protection = Not_applicable;
          git_protection = Not_applicable;
        };
      identity = User_identity.Image;
    }
  in
  let resolve plan =
    Assemble_plan.resolve ~image_id:"iid" ~container_id:"cid"
      plan.Assemble_plan.create
  in
  let plain = get (Assemble_plan.make (loaded "" [])) in
  assert (
    not
      (List.exists
         (fun arg -> arg = "--env" || arg = "--env-file")
         (resolve plain)));
  let configured =
    loaded
      "container.workdir='/work'\n\
       container.cap_drop=['ALL']\n\
       container.env_files=['b.env','a.env']\n\
       [container.environment]\n\
       ZED='a secret; $(rm -rf /)'\n\
       ALPHA=''\n"
      [ "/project/b.env"; "/host/a.env" ]
  in
  let plan = get (Assemble_plan.make configured) in
  let rec after flag = function
    | x :: rest when x = flag -> rest
    | _ :: rest -> after flag rest
    | [] -> failwith flag
  in
  let rec take n = function
    | x :: rest when n > 0 -> x :: take (n - 1) rest
    | _ -> []
  in
  assert (
    take 9 (after "--cap-drop=ALL" (resolve plan))
    = [
        "--env-file";
        "/project/b.env";
        "--env-file";
        "/host/a.env";
        "--env";
        "ZED=a secret; $(rm -rf /)";
        "--env";
        "ALPHA=";
        "--workdir";
      ]);
  let preview = Assemble_plan.render plan in
  let contains text =
    let rec loop i =
      i + String.length text <= String.length preview
      && (String.sub preview i (String.length text) = text || loop (i + 1))
    in
    loop 0
  in
  assert (contains "--env-file /project/b.env \\\n");
  assert (contains "--env 'ZED=<hidden>' \\\n");
  assert (contains "--env 'ALPHA=<hidden>' \\\n");
  assert (not (contains "secret"));
  assert (not (contains "ALPHA= "));
  (* Escaping for previews keeps the actual value intact. *)
  assert (
    Command_plan.resolve ~image_id:"iid" ~container_id:"cid"
      (Command_plan.escape_literals plan.create)
    = resolve plan);
  (* A NUL in a hidden value is still rejected, even past validation. *)
  let base = loaded "" [] in
  assert (
    Result.is_error
      (Assemble_plan.make
         {
           base with
           effective =
             {
               base.effective with
               container =
                 {
                   base.effective.container with
                   environment = [ ("A", "x\000y") ];
                 };
             };
         }))
