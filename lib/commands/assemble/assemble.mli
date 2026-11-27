type runner =
  Process.output -> string list -> (Process.result, Process.error) result
(** Assemble a successfully loaded project. Failures retain managed resources.
*)

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Hook of Hook.failure
      (** A hook failed after the container was started; it is left running. *)

type error = { cause : cause; completed : string list }

type outcome = {
  image_id : string;
  container_id : string;
  created : bool;
  started : bool;
}

val compatibility :
  ?selinux_enabled:bool ->
  Config_loader.t ->
  Podman.image ->
  Podman.container ->
  (unit, string) result

val run :
  ?execute:runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  ?hook:Hook.runner ->
  ?warn:(string -> unit) ->
  ?on_ready:(outcome -> (unit, cause) result) ->
  Config_loader.t ->
  (outcome, error) result
(** Inspect, build the missing image, create the missing container and start it,
    verifying each step. [on_ready] is called once the container is verified
    running, before any hook; an error from it fails the run with that cause and
    runs no hook. Then a container on its first start (created by this run, or
    created earlier but never started) runs [post_create], and a created or
    started container runs [post_start], with [hook]; an already running
    container runs no hook. A failed hook stops later hooks and leaves the
    container running. Just before creating a container, the
    {!Assemble_plan.unprotected_git} warning, if any, is passed to [warn]. *)
