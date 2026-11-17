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

val stop : string -> string list
(** Stop the selected local container using Podman's default timeout. *)

val remove_container : string -> string list
(** Remove one container without force or volume removal. *)

val remove_image : string -> string list
(** Remove one image without force or pruning dangling parents. *)
