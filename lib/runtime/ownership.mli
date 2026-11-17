type conflict = { label : string; expected : string; actual : string list }
(** [actual] preserves all observed values: empty means missing, a singleton
    means mismatched, and multiple values mean duplicated. *)

val verify :
  project:string ->
  project_root:string ->
  Podman.labels ->
  (unit, conflict list) result
(** Pure resource ownership checks. [project_root] must already be canonical. *)

type identity = { uid : int; gid : int }

val identity : Podman.labels -> (identity option, string) result
(** Missing identity is [Ok None]; malformed or duplicate identity labels fail.
*)
