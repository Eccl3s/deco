type t = private {
  container_name : string;
  image_reference : string;
  keep_image : bool;
  stop : Command_plan.argument list;
  remove_container : Command_plan.argument list;
  build : string list option;  (** [None] when keeping the image. *)
  create : Command_plan.argument list;
  start : Command_plan.argument list;
}
(** Pure refresh planning; performs no Podman calls or filesystem access.
    Commands are taken from {!Assemble_plan} and {!Remove_plan} so refresh
    builds, creates, stops, and removes exactly as those commands do. *)

val make : Config_loader.t -> keep_image:bool -> (t, string) result
(** Plan a refresh. [keep_image] omits the rebuild and requires the configured
    image to exist at run time. Errors from the underlying planners, such as NUL
    bytes in arguments, are returned unchanged. Volumes and hooks are deferred.
*)

val render : t -> string
(** Describe the complete ordered operation, marking conditional and destructive
    steps. Current resource state is not queried; resource IDs are shown as
    placeholders. *)
