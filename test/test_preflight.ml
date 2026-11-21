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
  let ok = Ok { Process.status = Unix.WEXITED 0; stdout = "{}"; stderr = "" } in
  let failed =
    Ok
      { Process.status = Unix.WEXITED 125; stdout = ""; stderr = "unavailable" }
  in
  let fallback = ref 0 in
  let run argv =
    incr fallback;
    assert (argv = Podman_command.version);
    failed
  in
  let batches = ref 0 in
  let read_many commands =
    incr batches;
    assert (List.hd commands = Podman_command.version);
    List.map (fun _ -> ok) commands
  in
  let reader =
    Result.get_ok
      (Container_runtime.preflight ~run ~read_many [ Podman_command.version ])
  in
  assert (reader Podman_command.version = ok && !fallback = 0);
  assert (
    reader Podman_command.version = failed && !fallback = 1 && !batches = 1);
  assert (
    Result.is_error
      (Container_runtime.preflight ~run
         ~read_many:(fun _ -> [])
         [ Podman_command.version ]));
  let reader =
    Result.get_ok
      (Container_runtime.preflight ~run
         [ Podman_command.version; [ "never-run" ] ])
  in
  assert (!fallback = 1);
  assert (reader Podman_command.version = failed && !fallback = 2);
  let forbidden _ = failwith "Batch failure invoked fallback" in
  let read_many commands =
    assert (List.hd commands = Podman_command.version);
    List.mapi
      (fun i _ ->
        if i = 0 then failed
        else Error { Process.operation = "launch"; message = "also failed" })
      commands
  in
  (match Container_runtime.inspect ~run:forbidden ~read_many loaded with
  | Error (Container_runtime.Podman (Podman.Unavailable _)) -> ()
  | _ -> assert false);
  (match Stop.run ~run:forbidden ~read_many loaded with
  | Error { Stop.cause = Podman (Podman.Unavailable _); _ } -> ()
  | _ -> assert false);
  match Remove.run ~run:forbidden ~read_many loaded ~keep_image:false with
  | Error { Remove.cause = Podman (Podman.Unavailable _); completed = [] } -> ()
  | _ -> assert false
