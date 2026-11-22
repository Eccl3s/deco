open Deco

let get = function Ok x -> x | Error _ -> failwith "unexpected planning error"

let contains text fragment =
  let rec loop i =
    i + String.length fragment <= String.length text
    && (String.sub text i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "[project]\n\
          name = 'example'\n\
          [actions]\n\
          test = 'make test'\n\
          Hostile = \"printf '\\u001b[31m'\"\n")
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
  let resolve = Command_plan.resolve ~image_id:"unused" ~container_id:"cid" in
  (* The action runs as <shell> -lc <command> with exec's TTY flags. *)
  List.iter
    (fun tty ->
      let plan = get (Run_plan.make loaded ~tty "test") in
      assert (plan.name = "test" && plan.command = "make test");
      assert (plan.argv = [ "sh"; "-lc"; "make test" ]);
      assert (
        resolve plan.exec.exec
        = [ "podman"; "--remote=false"; "exec"; "--interactive" ]
          @ (if tty then [ "--tty" ] else [])
          @ [ "--"; "cid"; "sh"; "-lc"; "make test" ]))
    [ false; true ];
  (* The configured shell is used. *)
  let bash =
    {
      loaded with
      effective =
        {
          loaded.effective with
          container = { loaded.effective.container with shell = "/bin/bash" };
        };
    }
  in
  assert (
    (get (Run_plan.make bash ~tty:false "test")).argv
    = [ "/bin/bash"; "-lc"; "make test" ]);
  (* Names are matched exactly. *)
  List.iter
    (fun name ->
      assert (
        Run_plan.make loaded ~tty:false name
        = Error (Run_plan.Unknown_action name)))
    [ "nope"; "Test"; "hostile"; "" ];
  (* NUL bytes in the user or workdir are rejected through Exec_plan. *)
  (match
     Run_plan.make
       {
         loaded with
         effective =
           {
             loaded.effective with
             container =
               {
                 loaded.effective.container with
                 workdir = Some "/work\000space";
               };
           };
       }
       ~tty:false "test"
   with
  | Error (Run_plan.Planning _) -> ()
  | _ -> assert false);
  (* The preview lists preparation, then the action. *)
  let rendered =
    Run_plan.render (get (Run_plan.make loaded ~tty:false "test"))
  in
  assert (
    String.starts_with ~prefix:"Run preview\nNo commands will be run.\n"
      rendered);
  assert (contains rendered "3. If the container is not running, start it:");
  assert (contains rendered "4. Run action test:\n");
  assert (contains rendered "'make test'");
  assert (not (contains rendered "post_start"));
  (* A post_start hook is listed after the start and before the action. *)
  let hooked =
    {
      loaded with
      effective =
        {
          loaded.effective with
          hooks = { loaded.effective.hooks with post_start = Some "echo ready" };
        };
    }
  in
  let rendered =
    Run_plan.render (get (Run_plan.make hooked ~tty:false "test"))
  in
  assert (
    contains rendered
      "4. If the container was started, run the post_start hook:\n");
  assert (contains rendered "5. Run action test:\n");
  (* Commands from configuration are escaped in the preview. *)
  let rendered =
    Run_plan.render (get (Run_plan.make loaded ~tty:false "Hostile"))
  in
  assert (not (String.contains rendered '\027'));
  assert (contains rendered "\\x1b[31m")
