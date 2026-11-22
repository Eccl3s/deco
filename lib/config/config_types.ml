type user_mode = Keep_id | Image
type id_source = Host | Id of int
type relabel = Shared | Private | No_relabel
type project = { name : string; description : string option }
type image = { name : string option; tag : string option }

type build = {
  context : string option;
  containerfile : string option;
  target : string option;
  pull : bool option;
  no_cache : bool option;
  args : (string * string) list;
}

type user = {
  name : string option;
  mode : user_mode option;
  uid : id_source option;
  gid : id_source option;
}

type container = {
  name : string option;
  workdir : string option;
  shell : string option;
}

type workspace = {
  source : string option;
  target : string;
  relabel : relabel option;
}

type mounts = { workspace : workspace option }

type hooks = {
  post_create : string option;
  post_start : string option;
  pre_enter : string option;
  pre_stop : string option;
}

type t = {
  project : project;
  image : image option;
  build : build option;
  user : user option;
  container : container option;
  mounts : mounts option;
  hooks : hooks option;
  actions : (string * string) list option;
}
