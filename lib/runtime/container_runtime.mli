(** Read-only runtime checks shared by lifecycle commands. *)
type error = Podman of Podman.error | Conflict of string

type environment = { image : Podman.image; container : Podman.container }

val incompatibilities :
  ?selinux_enabled:bool ->
  Config_loader.t ->
  Podman.image ->
  Podman.container ->
  string list
(** Every way the container differs from the loaded configuration and the image,
    in a fixed order; empty when compatible. Ownership is not checked.
    [selinux_enabled] (default [true]) decides whether a missing relabel option
    can be verified. *)

val hook_incompatibilities : Config_loader.t -> Podman.container -> string list
(** The ways the container differs from the loaded configuration that matter for
    running a hook in it with the configured user and workdir: the keep-id user
    and identity label, and an explicitly configured workdir. Unlike
    {!incompatibilities}, the image and init are not compared, so a container
    whose image was rebuilt since it was created can still run hooks. *)

val compatibility :
  ?selinux_enabled:bool ->
  Config_loader.t ->
  Podman.image ->
  Podman.container ->
  (unit, string) result
(** {!incompatibilities} as a result, joining the messages with ["; "]. *)

val selinux_enabled : string -> bool
(** Conservatively assume SELinux is enabled when detection fails. *)

val availability : ?run:Podman.runner -> unit -> (bool, Podman.error) result
(** Check Podman and return its SELinux setting. *)

type resource =
  | Image of string
  | Container of string
      (** A resource and the reference used to select it: the configured
          [name:tag] or name, or a supplied ID. *)

val verify_ownership :
  Config_loader.t -> resource -> Podman.labels -> (unit, error) result
(** Check that [labels] carry the loaded project's ownership labels. Otherwise
    fail with a [Conflict] whose message comes from {!Ownership.describe} and
    names the resource by its reference. The single ownership check used before
    any lifecycle operation. *)

val inspect :
  ?run:Podman.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  ?selinux:(unit -> (bool, Podman.error) result) ->
  ?container_id:string ->
  Config_loader.t ->
  (environment, error) result
(** Require existing owned, compatible resources in an assemble-supported state.
    When supplied, [container_id] selects the container by ID instead of its
    configured name; the image is still selected from project configuration.
    SELinux detection is lazy. [probe] supplies local status; [selinux]
    overrides the complete detection operation, allowing invocation-scoped
    caching. Never mutate resources or print output. *)

val never_started : string -> bool
(** Whether a container in this Podman state has never been started ([created]
    or [configured]). Such a container still owes its [post_create] hook, even
    when an earlier run created it. *)

val supported_state : string -> bool
(** Whether assemble and existing-environment inspection support this state. *)

val local_selinux : ?root:string -> unit -> bool option
(** Read local sysfs: permissive and enforcing both mean enabled; uncertain
    results return [None]. [root] defaults to [/sys/fs/selinux]. *)

val make_selinux_resolver :
  ?run:Podman.runner ->
  ?probe:(unit -> bool option) ->
  unit ->
  unit ->
  (bool, Podman.error) result

val check_compatibility :
  selinux:(unit -> (bool, Podman.error) result) ->
  Config_loader.t ->
  Podman.image ->
  Podman.container ->
  (unit, error) result

val inspect_owned_container :
  ?run:Podman.runner ->
  ?container_id:string ->
  Config_loader.t ->
  (Podman.container Podman.presence, error) result
(** Inspect by configured name or supplied ID and verify project ownership.
    Preserve absence; do not check availability, image, compatibility, or
    SELinux. *)

val inspect_owned_image :
  ?run:Podman.runner ->
  ?image_id:string ->
  Config_loader.t ->
  (Podman.image Podman.presence, error) result
(** Inspect the configured image or supplied [image_id], preserving absence and
    verifying project ownership without environment compatibility checks. *)

val preflight :
  ?run:Podman.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  string list list ->
  (Podman.runner, Podman.error) result
(** Prefetch independent reads when batching is enabled. Results are consumed
    once; injected single runners retain sequential fail-fast execution. *)
