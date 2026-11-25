type t = {
  build_context : string;
  containerfile : string;
  workspace_source : string option;
  env_files : string list;
      (** Canonical [container.env_files] paths, in configured order. *)
}
(** Canonical host paths checked against the current filesystem. Success does
    not guarantee future availability, container permissions or runtime
    compatibility. Every Containerfile, including relative and symlink paths,
    must remain inside the canonical context: this is Deco's containment
    interpretation. *)

val resolve :
  ?home_dir:string ->
  project:Project.t ->
  Config.Effective.t ->
  (t, Config.Diagnostic.t list) result
(** Does not change inputs or cwd. Relative host paths use the canonical project
    root, except Containerfiles which use the build context. Each env file must
    be an existing regular file; unlike the Containerfile it may be anywhere on
    the host. Expands only ~ and ~/; environment references remain literal. Home
    lookup is lazy and defaults to the current Unix user's passwd entry. An
    override must be absolute when used. Independent errors are collected and
    sorted; invalid contexts suppress Containerfile checks. Does not read config
    contents or create resources. *)
