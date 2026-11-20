type t = private { container_name : string; start : Command_plan.argument list }
(** Pure start planning; no runtime queries, filesystem access, or writes. *)

val make : Config_loader.t -> (t, string) result
(** Plan a start by inspected ID; reject NUL bytes in names or literals. *)

val render : t -> string
(** Describe conditional start, already-running behavior, and verification, and
    note that the [post_start] hook is deferred. No runtime state is evaluated.
*)
