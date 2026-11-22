type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Hook of Hook.failure
      (** A hook failed after the start; the container is left running. *)

type error = { cause : cause; started : bool }
(** [started] records a successful Podman start, even if verification fails. *)

type outcome = { environment : Container_runtime.environment; started : bool }
(** [environment] is the verified running environment. [started] means a start
    was performed and verified; it is [false] for an already running container.
*)

val run :
  ?run:Podman.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  ?hook:Hook.runner ->
  Config_loader.t ->
  (outcome, error) result
(** Require an existing owned, compatible environment in a supported state (see
    {!Container_runtime.inspect}), then start the container by inspected ID if
    it is not running. After a start, reinspect the same container and require
    unchanged container and image IDs and a running state, then run the
    [post_start] hook with [hook] (see {!Hook.run}), preceded by [post_create]
    when the container had never been started. An already running container runs
    no hook. Initial reads are batched with [read_many], which defaults to
    concurrent reads unless only [run] is injected. [probe] supplies local
    SELinux status. No printing, exit mapping, or signal handling; callers may
    supply a signal-aware runner. *)
