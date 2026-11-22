type t = private {
  start : Command_plan.argument list;
  post_start : string option;
      (** The rendered step for the configured [post_start] hook. *)
  exec : Command_plan.argument list;
}
(** Pure exec planning; performs no terminal detection or runtime queries. *)

val make : Config_loader.t -> tty:bool -> string list -> (t, string) result
(** Reject an empty argument list; otherwise preserve command arguments exactly.
*)

val prepare : t -> string list
(** The preparation steps shared with [deco shell]: availability, inspection,
    the conditional start and the [post_start] hook that follows it. *)

val render : t -> string
(** Describe conditional preparation and execution without querying Podman. *)
