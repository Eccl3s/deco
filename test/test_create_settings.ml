open Deco

let load text =
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
       };
     identity = User_identity.Image;
   }
    : Config_loader.t)

let () =
  assert (Create_settings.label = "dev.deco.create-digest");
  (* Stable, and formatted like the trust digest. *)
  let empty = Create_settings.digest [] in
  assert (empty = Create_settings.digest []);
  let prefix = "blake2b-256:" in
  assert (String.starts_with ~prefix empty);
  let hex = String.sub empty 12 (String.length empty - 12) in
  assert (String.length hex = 64);
  assert (
    String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) hex);
  (* Known answers, computed independently, guard the persisted encoding: any
     drift would make every labelled container incompatible. *)
  assert (
    empty
    = "blake2b-256:0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8");
  assert (
    Create_settings.digest [ ("container.cap_drop", "ALL") ]
    = "blake2b-256:587eb695f312145d7d6f45fef290546f139b18a17792f8612e1c98218c8f714b");
  (* Order does not matter; content does. *)
  let a = [ ("container.cap_drop", "ALL"); ("network.mode", "pasta") ] in
  assert (Create_settings.digest a = Create_settings.digest (List.rev a));
  assert (Create_settings.digest a <> empty);
  assert (
    Create_settings.digest [ ("k", "a") ]
    <> Create_settings.digest [ ("k", "b") ]);
  (* Length prefixes keep key/value boundaries distinct. *)
  assert (
    Create_settings.digest [ ("ab", "c") ]
    <> Create_settings.digest [ ("a", "bc") ]);
  assert (
    Create_settings.digest [ ("a", ""); ("b", "") ]
    <> Create_settings.digest [ ("a", "b") ]);
  (* Duplicate keys are a programming error. *)
  assert (
    match Create_settings.digest [ ("k", "a"); ("k", "b") ] with
    | _ -> false
    | exception Invalid_argument _ -> true);
  (* No setting contributes yet, so every configuration matches a container
     created before the label existed. *)
  let loaded =
    load
      "project.name='example'\n\
       container.workdir='/work'\n\
       container.shell='/bin/zsh'\n\
       hooks.post_start='echo ready'\n"
  in
  assert (Create_settings.fields loaded = []);
  assert (Create_settings.of_loaded loaded = empty)
