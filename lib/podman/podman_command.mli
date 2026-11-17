val info : string list
(** Shared read-only command construction for execution and previews. *)

val exists : string -> string -> string list
val inspect : string -> string -> string list
val start : string -> string list

val exec :
  tty:bool ->
  user:string option ->
  workdir:string option ->
  container:string ->
  string list ->
  string list
(** Construct an exec argument vector without evaluating command arguments. *)

val version : string list
