type t = private {
  container_name : string;
  stop : Command_plan.argument list;
  pre_stop : string option;
      (** The rendered step for the configured [pre_stop] hook; [None] when it
          is not set or hooks are disabled. *)
}
(** Pure stop planning; no runtime queries, filesystem access, or writes. *)

val pre_stop_step : Config_loader.t -> hooks:bool -> string option
(** The dry-run step for the configured [pre_stop] hook, for
    {!Command_plan.render_steps}; [None] when it is not set or [hooks] is false.
*)

val make : ?hooks:bool -> Config_loader.t -> (t, string) result
(** Plan shutdown by inspected ID; reject NUL bytes in names or literals.
    [hooks] (default [true]) is false for [--no-hooks]. *)

val render : t -> string
(** Describe the [pre_stop] hook, conditional shutdown, already-stopped
    behavior, and verification. No runtime state is evaluated. *)
