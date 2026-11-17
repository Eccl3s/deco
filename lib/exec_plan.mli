type t = private {
  start : Assemble_plan.argument list;
  exec : Assemble_plan.argument list;
}
(** Pure exec planning; performs no terminal detection or runtime queries. *)

val make : Config_loader.t -> tty:bool -> string list -> (t, string) result
(** Reject an empty argument list; otherwise preserve command arguments exactly.
*)

val render : t -> string
(** Describe conditional preparation and execution without querying Podman. *)
