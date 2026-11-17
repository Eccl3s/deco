(** Read-only runtime checks shared by lifecycle commands. *)
type error = Podman of Podman.error | Conflict of string

type environment = { image : Podman.image; container : Podman.container }

val compatibility :
  ?selinux_enabled:bool ->
  Config_loader.t ->
  Podman.image ->
  Podman.container ->
  (unit, string) result

val selinux_enabled : string -> bool
(** Conservatively assume SELinux is enabled when detection fails. *)

val availability : ?run:Podman.runner -> unit -> (bool, Podman.error) result
(** Check Podman and return its SELinux setting. *)

val inspect :
  ?run:Podman.runner ->
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
