type mutation =
  | Stop_container
  | Remove_container
  | Build_image
  | Create_container
  | Start_container

type outcome = {
  stopped : bool;  (** The old container was running and was stopped. *)
  container_removed : bool;  (** An old container existed and was removed. *)
  image_rebuilt : bool;  (** [false] only with [keep_image]. *)
  image_id : string;
  container_id : string;  (** The replacement container. *)
}

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Container_appeared
      (** A container with the configured name appeared after the old one was
          removed, so no replacement was created. The appeared container was
          left in place, and may have been started. *)
  | Hook of Hook.failure
      (** A hook failed in the replacement container, which is left running. *)

type error = { cause : cause; completed : mutation list }
(** [completed] lists successful mutations in order. Unless the cause is
    [Container_appeared], a list containing [Remove_container] but not
    [Start_container] means the old container is gone and no replacement is
    running: a partial refresh that is never rolled back. *)

(** Stages reported in order as they complete, so callers can show progress
    while the refresh runs. Nothing is reported after a failure. *)
type progress =
  | Image_rebuilt  (** The image was rebuilt and verified. *)
  | Image_kept  (** [keep_image]: the existing image is used. *)
  | Container_removed of { stopped : bool }
      (** The old container was removed; [stopped] if it had been running. *)
  | No_container  (** There was no old container to remove. *)
  | Container_started  (** The replacement was created and started. *)

val run :
  ?execute:Assemble.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  ?hook:Hook.runner ->
  ?progress:(progress -> unit) ->
  Config_loader.t ->
  keep_image:bool ->
  (outcome, error) result
(** Refresh a successfully loaded project. Before any mutation, check Podman
    availability, verify ownership of an existing container and image, and with
    [keep_image] require the image to exist. Then rebuild the image unless
    [keep_image] (the build inherits the terminal) while the old container keeps
    running, so a failed build changes no container. Then stop and remove the
    old container (via {!Remove.run}) and create and start the replacement (via
    {!Assemble.run}), failing with [Container_appeared] if assemble reused a
    container instead of creating one. [read_many] batches the initial
    inspections only. [progress] is called as each stage completes. The previous
    image is left in place, and no output, hooks, or volumes are handled. *)
