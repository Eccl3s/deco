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
              workspace = Some { source = "."; target = "/workspace"; relabel };
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
       5. If the container was created, run the post_create hook:\n\
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
