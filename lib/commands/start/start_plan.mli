type t = private {
  container_name : string;
  start : Command_plan.argument list;
  post_create : Command_plan.argument list option;
      (** The configured [post_create] hook, owed by a container that has never
          been started; [None] when it is not set. *)
  post_start : Command_plan.argument list option;
      (** The configured [post_start] hook; [None] when it is not set. *)
}
(** Pure start planning; no runtime queries, filesystem access, or writes. *)

val make : Config_loader.t -> (t, string) result
(** Plan a start by inspected ID; reject NUL bytes in names or literals. *)

val hook_steps : t -> string list
(** The dry-run steps for the configured hooks that follow a start, for
    {!Command_plan.render_steps}: [post_create] when the container had never
    been started, then [post_start]. *)

val render : t -> string
(** Describe conditional start, already-running behavior, verification, and the
    configured hooks that run after a start. No runtime state is evaluated. *)
