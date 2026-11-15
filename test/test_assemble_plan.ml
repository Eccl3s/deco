open Deco

let get = function Ok x -> x | Error e -> failwith e

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname = 'example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
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
  assert (List.length plan.steps = 8);
  assert (
    (List.hd plan.steps).command
    = List.map (fun s -> Assemble_plan.Literal s) Podman_command.info);
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
      "podman info";
      "'<image-id>'";
      "'<container-id>'";
      "container example-dev-container is missing";
      "container example-dev-container is new or stopped";
      "image example-dev-image:latest is missing";
      "'VALUE=hello world'";
      "After ownership and compatibility checks pass";
      "resolved during execution";
    ];
  assert (
    Assemble_plan.render custom_plan
    = Assemble_plan.render (get (Assemble_plan.make custom)))
