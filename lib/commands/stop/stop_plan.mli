type t = private { container_name : string; stop : Command_plan.argument list }
(** Pure stop planning; no runtime queries, filesystem access, or writes. *)

val make : Config_loader.t -> (t, string) result
(** Plan shutdown by inspected ID; reject NUL bytes in names or literals. *)

val render : t -> string
(** Describe conditional shutdown, already-stopped behavior, and verification.
    No hooks or runtime state are evaluated. *)
