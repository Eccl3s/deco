type t = private {
  container_name : string;
  image_reference : string option;
  stop : Command_plan.argument list;
  remove_container : Command_plan.argument list;
  remove_image : Command_plan.argument list option;
}
(** Pure removal planning; performs no Podman calls or filesystem access. *)

val make : Config_loader.t -> keep_image:bool -> (t, string) result
(** Omit image operations entirely when keeping the image. Reject NUL bytes in
    included references and literals. Force, volumes, and hooks are deferred. *)

val render : t -> string
(** Describe conditional shutdown/removal, dependency refusal, and verification.
    Current resource state and dependent containers are not queried. *)
