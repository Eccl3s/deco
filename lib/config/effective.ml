type project = Config_types.project
type image = { name : string; tag : string }

type build = {
  context : string;
  containerfile : string;
  target : string option;
  pull : bool;
  no_cache : bool;
  args : (string * string) list;
}

type user = {
  name : string option;
  mode : Config_types.user_mode;
  uid : Config_types.id_source option;
  gid : Config_types.id_source option;
}

type container = { name : string; workdir : string option; shell : string }

type workspace = {
  source : string;
  target : string;
  relabel : Config_types.relabel;
}

type mounts = { workspace : workspace option }

type hooks = Config_types.hooks = {
  post_create : string option;
  post_start : string option;
  pre_enter : string option;
  pre_stop : string option;
}

type t = {
  project : project;
  image : image;
  build : build;
  user : user;
  container : container;
  mounts : mounts;
  hooks : hooks;
}

let image_reference (image : image) = image.name ^ ":" ^ image.tag

let configured_hooks (hooks : hooks) =
  List.filter_map
    (fun (name, value) -> Option.map (fun value -> (name, value)) value)
    [
      ("post_create", hooks.post_create);
      ("post_start", hooks.post_start);
      ("pre_enter", hooks.pre_enter);
      ("pre_stop", hooks.pre_stop);
    ]
