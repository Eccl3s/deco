(** Deco configuration model.

    This module defines the OCaml representation of the subset of
    [.deco/config.toml] supported by Deco v0.1.0, as specified in
    [specs/deco-config.md]. It defines the configuration types used by the
    decoder, partial pure validator, and default resolver. These decoded types
    retain omissions; [Effective] represents default-filled values. Remaining
    semantic and runtime validation and serialisation are deferred.

    Conventions:

    - Required TOML values are plain fields. Optional values are ['a option],
      where [None] means the key was omitted from the file.
    - Top-level tables that may be omitted entirely are ['a option] fields.
    - Key/value tables are association lists; table entry order has no semantic
      meaning.
    - Closed sets of string values are variant types.
    - No default values are resolved here; [None] always means "omitted".

    Tables from the v1 specification that the v0.1.0 commands do not need are
    intentionally not modelled yet: [[container.namespaces]],
    [[container.secrets]], [[network]], [[network.ports]], [[mounts.volumes]],
    [[hooks]], [[container.environment]], and [[actions]]. Runtime environment
    files, privileged mode, devices, capabilities, security options, and user
    modes ["host-user"] and ["root"] are also deferred. Future parsing must
    reject deferred features rather than silently ignore them. Generated
    templates will explicitly select ["keep-id"] with account ["dev"]; omitted
    user configuration retains the v1 ["image"] default. *)

(** User identity strategy from [[user.mode]]. *)
type user_mode =
  | Keep_id  (** TOML ["keep-id"]: map host UID/GID into the container. *)
  | Image  (** TOML ["image"]: use the user configured by the image. *)

(** A UID or GID value from [[user]]: the literal ["host"] or an integer. *)
type id_source =
  | Host  (** TOML ["host"]: resolved from the current host user at runtime. *)
  | Id of int  (** An explicit integer UID/GID. *)

(** SELinux relabel policy from [[mounts.workspace.relabel]]. *)
type relabel =
  | Shared  (** TOML ["shared"]; equivalent to the [:z] mount option. *)
  | Private  (** TOML ["private"]; equivalent to the [:Z] mount option. *)
  | No_relabel  (** TOML ["none"]: do not request SELinux relabeling. *)

type project = {
  name : string;
      (** Required stable project identifier; engine resource names derive from
          it. *)
  description : string option;  (** Optional human-readable description. *)
}
(** The [[project]] table: project metadata. Required at the top level. *)

type image = {
  name : string option;
      (** Image repository name; default [<project.name>-dev-image]. *)
  tag : string option;  (** Image tag; default ["latest"]. *)
}
(** The [[image]] table: name of the locally built image. *)

type build = {
  context : string option;
      (** Host build context directory; default [".deco/build"]. *)
  containerfile : string option;
      (** Containerfile path; default ["Containerfile"], resolved against
          [context]. *)
  target : string option;
      (** Named multi-stage build target; none by default. *)
  pull : bool option;  (** Request newer base images; default [false]. *)
  no_cache : bool option;
      (** Disable reuse of cached build layers; default [false]. *)
  args : (string * string) list;
      (** [[build.args]] entries; empty by default. *)
}
(** The [[build]] table together with its [[build.args]] sub-table. *)

type user = {
  name : string option;
      (** Account name; required for [Keep_id]; must be omitted for [Image]. *)
  mode : user_mode option;  (** Identity strategy; default [Image]. *)
  uid : id_source option;
      (** UID for the generated [USER_UID] build arg and runtime identity. *)
  gid : id_source option;
      (** GID for the generated [USER_GID] build arg and runtime identity. *)
}
(** The [[user]] table: identity used for [deco exec] and [deco shell]. Omitted
    UID/GID values default to [Host] for [Keep_id]. *)

type container = {
  name : string option;
      (** Container name; default [<project.name>-dev-container]. *)
  workdir : string option;
      (** Absolute container working directory for exec and shell. *)
  shell : string option;  (** Executable used to run commands; default ["sh"]. *)
}
(** The [[container]] table. *)

type workspace = {
  source : string option;  (** Host directory to mount; default ["."]. *)
  target : string;  (** Required absolute container mount point. *)
  relabel : relabel option;  (** SELinux relabel policy; default [No_relabel]. *)
}
(** The [[mounts.workspace]] table: bind mount of the project workspace into the
    container. *)

type mounts = {
  workspace : workspace option;
      (** [[mounts.workspace]]; [None] when not configured. *)
}
(** The [[mounts]] table. Only the workspace mount is modelled in v0.1.0. *)

type t = {
  project : project;  (** Required: the [[project]] table must be present. *)
  image : image option;  (** [[image]]; [None] when omitted. *)
  build : build option;  (** [[build]]; [None] means all build defaults. *)
  user : user option;  (** [[user]]; [None] is equivalent to mode ["image"]. *)
  container : container option;  (** [[container]]; [None] when omitted. *)
  mounts : mounts option;  (** [[mounts]]; [None] when omitted. *)
}
(** The top-level configuration, mirroring [.deco/config.toml]. *)
