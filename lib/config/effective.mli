(** Default-filled configuration. This is not a fully validated runtime model.
    Paths are unresolved and host identities are symbolic. Optional workdir
    delegates to the image when absent. Values do not retain explicit/defaulted
    provenance; callers needing that distinction must retain the decoded config.
*)

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

type t = {
  project : project;
  image : image;
  build : build;
  user : user;
  container : container;
  mounts : mounts;
}
