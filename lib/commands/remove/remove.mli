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

type error = { cause : cause; completed : mutation list }
(** Completed mutations are ordered successful commands, not verified outcomes.
*)

val run :
  ?run:Podman.runner ->
  Config_loader.t ->
  keep_image:bool ->
  (outcome, error) result
(** Ownership-only removal by inspected IDs. No force, rollback, output, or
    hooks. *)
