type conflict = { label : string; expected : string; actual : string list }
(** [actual] preserves all observed values: empty means missing, a singleton
    means mismatched, and multiple values mean duplicated. *)

val verify :
  project:string ->
  project_root:string ->
  Podman.labels ->
  (unit, conflict list) result
(** Pure resource ownership checks. [project_root] must already be canonical. *)

val describe :
  kind:[ `Image | `Container ] -> reference:string -> conflict list -> string
(** Explain why a resource is not owned, for an error message. The first line
    names the resource by [reference] and says what owns it: something other
    than Deco, another Deco project, or a project with the same name at another
    root (a moved project looks like this). Then one line per conflicting label
    with its expected and found values, then a recovery hint. Removal is
    suggested only for a moved project, and only on condition that the old copy
    is gone, because the resource may belong to a live project. All values are
    escaped with {!Terminal_text.escape}. Lines are separated by ["\n"] with no
    trailing newline. *)

type identity = { uid : int; gid : int }

val identity : Podman.labels -> (identity option, string) result
(** Missing identity is [Ok None]; malformed or duplicate identity labels fail.
*)
