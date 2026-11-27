type protection =
  | Protected  (** Mounted read-only over its path in the workspace. *)
  | Unprotected
      (** Inside the workspace but not mounted read-only: [.git] exists and is
          not a directory, such as a linked worktree's or submodule's [.git]
          file. Deco warns about it. *)
  | Disabled  (** [mounts.workspace.protect_git = false]. *)
  | Not_applicable
      (** No workspace, the path is outside the workspace source, or [.git] does
          not exist. *)

type protected_path = {
  source : string;  (** Canonical host path. *)
  target : string;  (** Its path in the container, under the workspace. *)
}
(** A workspace path that [podman create] mounts read-only
    ([specs/deco-config.md], Protected workspace paths). *)

type t = {
  build_context : string;
  containerfile : string;
  workspace_source : string option;
  env_files : string list;
      (** Canonical [container.env_files] paths, in configured order. *)
  protected : protected_path list;
      (** The [.deco] directory, then the [.git] directory, each when
          {!Protected}. *)
  deco_protection : protection;
      (** {!Protected} when the directory [.deco] resolves to lies inside the
          canonical workspace source, otherwise {!Not_applicable}. *)
  git_protection : protection;
      (** For [<project root>/.git], checked with [lstat] and never parsed:
          {!Protected} for a directory inside the workspace source,
          {!Unprotected} for anything else that exists there (a file or a
          symbolic link), {!Disabled} when [protect_git] is [false], and
          {!Not_applicable} otherwise. *)
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
    sorted; invalid contexts suppress Containerfile checks. Protection is
    determined from the filesystem at resolution time, so a [.git] created later
    is reflected the next time the configuration is loaded. Does not read config
    contents or create resources. *)
