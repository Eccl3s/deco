type t = private {
  container_name : string;
  start : Command_plan.argument list;
  post_start : Command_plan.argument list option;
      (** The configured [post_start] hook; [None] when it is not set. *)
}
(** Pure start planning; no runtime queries, filesystem access, or writes. *)

val make : Config_loader.t -> (t, string) result
(** Plan a start by inspected ID; reject NUL bytes in names or literals. *)

val post_start_step : t -> string option
(** The dry-run step for the configured [post_start] hook, which runs only when
    the container was started, for {!Command_plan.render_steps}. *)

val render : t -> string
(** Describe conditional start, already-running behavior, verification, and the
    configured [post_start] hook that runs after a start. No runtime state is
    evaluated. *)
