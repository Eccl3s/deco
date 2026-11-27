let apply (config : Config_types.t) =
  match Validate.check config with
  | Error errors -> Error errors
  | Ok () ->
      let get table field default =
        Option.value ~default (Option.bind table field)
      in
      let workspace : Effective.workspace option =
        Option.map
          (fun (workspace : Config_types.workspace) ->
            Effective.
              {
                source = Option.value ~default:"." workspace.source;
                target = workspace.target;
                relabel =
                  Option.value ~default:Config_types.No_relabel
                    workspace.relabel;
                protect_git = Option.value ~default:true workspace.protect_git;
              })
          (Option.bind config.mounts (fun mounts -> mounts.workspace))
      in
      let mode = get config.user (fun user -> user.mode) Config_types.Image in
      let identity field =
        match (Option.bind config.user field, mode) with
        | None, Config_types.Keep_id -> Some Config_types.Host
        | value, _ -> value
      in
      let image : Effective.image =
        {
          name =
            get config.image
              (fun image -> image.name)
              (config.project.name ^ "-dev-image");
          tag = get config.image (fun image -> image.tag) "latest";
        }
      in
      let build : Effective.build =
        {
          context = get config.build (fun build -> build.context) ".deco/build";
          containerfile =
            get config.build (fun build -> build.containerfile) "Containerfile";
          target = Option.bind config.build (fun build -> build.target);
          pull = get config.build (fun build -> build.pull) false;
          no_cache = get config.build (fun build -> build.no_cache) false;
          args =
            Option.fold ~none:[]
              ~some:(fun (build : Config_types.build) -> build.args)
              config.build;
        }
      in
      let user : Effective.user =
        {
          name = Option.bind config.user (fun user -> user.name);
          mode;
          uid = identity (fun user -> user.uid);
          gid = identity (fun user -> user.gid);
        }
      in
      let container : Effective.container =
        {
          name =
            get config.container
              (fun container -> container.name)
              (config.project.name ^ "-dev-container");
          shell = get config.container (fun container -> container.shell) "sh";
          privileged =
            get config.container (fun container -> container.privileged) false;
          devices = get config.container (fun container -> container.devices) [];
          cap_add = get config.container (fun container -> container.cap_add) [];
          cap_drop =
            get config.container (fun container -> container.cap_drop) [];
          security_options =
            get config.container
              (fun container -> container.security_options)
              [];
          env_files =
            get config.container (fun container -> container.env_files) [];
          environment =
            get config.container (fun container -> container.environment) [];
          workdir =
            (match
               Option.bind config.container (fun container -> container.workdir)
             with
            | Some value -> Some value
            | None ->
                Option.map
                  (fun (workspace : Effective.workspace) -> workspace.target)
                  workspace);
        }
      in
      Ok
        Effective.
          {
            project = config.project;
            image;
            build;
            user;
            container;
            mounts = { workspace };
            hooks =
              Option.value config.hooks
                ~default:
                  {
                    post_create = None;
                    post_start = None;
                    pre_enter = None;
                    pre_stop = None;
                  };
            actions =
              List.sort
                (fun (a, _) (b, _) -> String.compare a b)
                (Option.value config.actions ~default:[]);
          }
