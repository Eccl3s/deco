type mutation = Stop_container | Remove_container | Remove_image

type outcome = {
  stopped : bool;
  container_removed : bool;
  image_removed : bool;
}

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Image_in_use of Podman.container_summary list
  | Hook of Hook.failure
      (** [pre_stop] failed; nothing was stopped or removed. *)

type error = { cause : cause; completed : mutation list }
(** Completed mutations are ordered successful commands, not verified outcomes.
*)

val run :
  ?run:Podman.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?hooks:bool ->
  ?hook:Hook.runner ->
  ?warn:(string -> unit) ->
  Config_loader.t ->
  keep_image:bool ->
  (outcome, error) result
(** Ownership-only removal by inspected IDs. A running container is stopped with
    {!Stop.run}, which runs [pre_stop] unless [hooks] is false; a failed hook
    prevents the removal. No force, rollback, or output. [read_many] batches
    initial version and selected resource inspections only. All later reads and
    mutations remain sequential and fresh. *)
