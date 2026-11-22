type t = private {
  container_name : string;
  image_reference : string option;
  stop : Command_plan.argument list;
  remove_container : Command_plan.argument list;
  remove_image : Command_plan.argument list option;
  pre_stop : string option;
      (** The rendered [pre_stop] step; [None] when it is not set or hooks are
          disabled. *)
}
(** Pure removal planning; performs no Podman calls or filesystem access. *)

val make :
  ?hooks:bool -> Config_loader.t -> keep_image:bool -> (t, string) result
(** Omit image operations entirely when keeping the image. Reject NUL bytes in
    included references and literals. [hooks] (default [true]) is false for
    [--no-hooks]. Force and volumes are deferred. *)

val render : t -> string
(** Describe the [pre_stop] hook, conditional shutdown/removal, dependency
    refusal, and verification. Current resource state and dependent containers
    are not queried. *)
