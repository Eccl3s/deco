(** Shared command arguments, resource substitution, and preview rendering. *)
type argument = Literal of string | Image_id | Container_id

val resolve :
  image_id:string -> container_id:string -> argument list -> string list

(* Substitute inspected resource IDs into a command template. *)
val render_command : argument list -> string

(* POSIX shell representation; symbolic IDs are explicitly marked placeholders. *)
val render_multiline : argument list -> string
(** Indented POSIX shell command with continuations between argument groups. *)

val render_steps : string list -> string
(** Number the steps from 1 in order, one per line group: each step is prefixed
    with ["N. "] and followed by a newline. Steps may span several lines. *)

val quote : string -> string
(** Quote a literal argument for POSIX shell display. *)
