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
  hooks : hooks;  (** Configured lifecycle hooks; all [None] when omitted. *)
}

val image_reference : image -> string
(** The configured image as Podman references it when building, inspecting and
    removing it: [name:tag]. The parts are joined as configured, with no
    normalisation; validation has already checked their syntax. *)

val configured_hooks : hooks -> (string * string) list
(** The configured hooks as [(key, command)] pairs in execution order:
    [post_create], [post_start], [pre_enter], [pre_stop]. *)
