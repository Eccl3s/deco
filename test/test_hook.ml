open Deco

let load ?(identity = User_identity.Image) text =
  let source = Result.get_ok (Config.Decode.from_string text) in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  ({
     ignored_paths = [];
     contents = "";
     project = { root = "/project"; config_path = "/project/.deco/config.toml" };
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
     identity;
   }
    : Config_loader.t)

let keep_id =
  User_identity.Keep_id
    {
      name = "dev";
      host = { uid = 1000; gid = 1000 };
      container = { uid = 1000; gid = 1000 };
    }

let () =
  (* Names follow the configuration keys. *)
  assert (
    List.map Hook.to_string
      [ Hook.Post_create; Post_start; Pre_enter; Pre_stop ]
    = [ "post_create"; "post_start"; "pre_enter"; "pre_stop" ]);
  (* Image mode without a workdir: no --user, no --workdir, no stdin, no TTY. *)
  let plain = load "project.name='example'\nhooks.post_start='echo ready'\n" in
  assert (Hook.configured plain Hook.Post_start = Some "echo ready");
  assert (Hook.configured plain Hook.Post_create = None);
  assert (Hook.command plain Hook.Pre_stop = None);
  let command = Option.get (Hook.command plain Hook.Post_start) in
  assert (
    command
    = Command_plan.
        [
          Literal "podman";
          Literal "--remote=false";
          Literal "exec";
          Literal "--";
          Container_id;
          Literal "sh";
          Literal "-c";
          Literal "echo ready";
        ]);
  assert (
    Hook.render_step ~condition:"If the container was started" Hook.Post_start
      command
    = "If the container was started, run the post_start hook:\n"
      ^ Command_plan.render_multiline command);
  let escaped =
    load "project.name='example'\nhooks.post_start=\"printf '\\u001b[2J'\"\n"
  in
  assert (
    not
      (String.contains
         (Hook.render_step ~condition:"If" Hook.Post_start
            (Option.get (Hook.command escaped Hook.Post_start)))
         '\027'));
  (* keep-id with a workdir and a custom shell. *)
  let configured =
    load ~identity:keep_id
      "project.name='example'\n\
       user={mode='keep-id',name='dev'}\n\
       container={workdir='/workspace',shell='/bin/bash'}\n\
       hooks.pre_stop='make clean'\n"
  in
  let calls = ref [] in
  let ok status = Ok { Process.status; stdout = ""; stderr = "" } in
  let runner result argv =
    calls := argv :: !calls;
    result
  in
  assert (
    Hook.run
      ~run:(runner (ok (Unix.WEXITED 0)))
      configured ~container_id:"cid" Hook.Pre_stop
    = Ok ());
  assert (
    !calls
    = [
        [
          "podman";
          "--remote=false";
          "exec";
          "--user";
          "dev";
          "--workdir";
          "/workspace";
          "--";
          "cid";
          "/bin/bash";
          "-c";
          "make clean";
        ];
      ]);
  assert (
    Command_plan.resolve ~image_id:"" ~container_id:"cid"
      (Option.get (Hook.command configured Hook.Pre_stop))
    = List.hd !calls);
  (* An unconfigured hook runs nothing. *)
  calls := [];
  assert (
    Hook.run
      ~run:(runner (ok (Unix.WEXITED 0)))
      configured ~container_id:"cid" Hook.Post_start
    = Ok ());
  assert (!calls = []);
  (* Failures keep the hook and its status. *)
  let failure =
    match
      Hook.run
        ~run:(runner (ok (Unix.WEXITED 7)))
        configured ~container_id:"cid" Hook.Pre_stop
    with
    | Error failure -> failure
    | Ok () -> assert false
  in
  assert (failure = Hook.Exited { hook = Pre_stop; status = WEXITED 7 });
  assert (Hook.exit_status failure = 7);
  assert (
    Hook.failure_message failure = "pre_stop hook failed with exit status 7");
  let signalled =
    Hook.Exited { hook = Post_start; status = Unix.WSIGNALED Sys.sigterm }
  in
  assert (Hook.exit_status signalled = 1);
  assert (
    Hook.failure_message signalled
    = "post_start hook terminated without a normal exit status");
  let launch =
    match
      Hook.run
        ~run:
          (runner
             (Error
                {
                  Process.operation = "launch";
                  message = "podman: command not found";
                }))
        configured ~container_id:"cid" Hook.Pre_stop
    with
    | Error failure -> failure
    | Ok () -> assert false
  in
  assert (Hook.exit_status launch = 1);
  assert (
    Hook.failure_message launch
    = "pre_stop hook could not be run: launch: podman: command not found");
  (* NUL bytes in hook commands are configuration errors. *)
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "project.name='example'\nhooks.pre_enter=\"a\\u0000b\"\n")
  in
  (match Config.Validate.check source with
  | Error [ { path = [ "hooks"; "pre_enter" ]; _ } ] -> ()
  | _ -> assert false);
  (* Only the user, identity and workdir decide whether a hook can run. *)
  let labels identity =
    [
      ("dev.deco.managed", "true");
      ("dev.deco.project", "example");
      ("dev.deco.project-root", "/project");
    ]
    @
    match identity with
    | None -> []
    | Some v -> [ ("dev.deco.user-identity", v) ]
  in
  let container ?(user = "dev") ?(workdir = "/workspace")
      ?(identity = Some "uid:1000,gid:1000") () : Podman.container =
    {
      id = "cid";
      labels = labels identity;
      state = "running";
      image_id = "old-image";
      user;
      userns = "";
      workdir;
      init = false;
      mounts = [];
      created = None;
    }
  in
  let check = Container_runtime.hook_incompatibilities configured in
  assert (check (container ()) = []);
  assert (check (container ~user:"root" ()) = [ "Container user differs" ]);
  assert (check (container ~identity:None ()) = [ "Identity label differs" ]);
  assert (check (container ~workdir:"/" ()) = [ "Working directory differs" ]);
  (* Image mode with no configured workdir never refuses. *)
  assert (
    Container_runtime.hook_incompatibilities plain
      (container ~user:"root" ~workdir:"/" ~identity:None ())
    = []);
  (* The recorded shell must match the configured one; containers without the
     label are not compared. configured uses /bin/bash. *)
  let shell value =
    {
      (container ()) with
      labels =
        (container ()).labels @ [ (Container_runtime.shell_label, value) ];
    }
  in
  assert (check (shell "/bin/bash") = []);
  assert (check (shell "sh") = [ "Container shell differs" ]);
  assert (
    check
      {
        (shell "/bin/bash") with
        labels =
          (shell "/bin/bash").labels @ [ (Container_runtime.shell_label, "x") ];
      }
    = [ "Shell label is duplicated" ]);
  (* Hooks do not depend on the create-settings digest. *)
  assert (
    check
      {
        (container ()) with
        labels =
          (container ()).labels @ [ (Create_settings.label, "blake2b-256:x") ];
      }
    = [])
