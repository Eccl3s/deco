(** Shared command arguments, resource substitution, and preview rendering. *)
type argument =
  | Literal of string
  | Redacted of { shown : string; actual : string }
      (** A literal whose real value, [actual], is passed to the command but
          must not be displayed; previews show [shown] instead. Used for
          environment-variable values. *)
  | Image_id
  | Container_id

val resolve :
  image_id:string -> container_id:string -> argument list -> string list

(* Substitute inspected resource IDs into a command template; a {!Redacted}
   argument contributes its actual value. *)

val value : argument -> string option
(** The value a {!Literal} or {!Redacted} argument passes to the command
    ([actual] for {!Redacted}), or [None] for a placeholder. *)

val contains_nul : argument list -> bool
(** Whether any argument's {!value} contains a NUL byte, which no process
    argument can carry. *)

val escape_literals : argument list -> argument list
(** Escape each {!Literal}, and the [shown] text of each {!Redacted} argument,
    with {!Terminal_text.escape}, keeping placeholders and actual values, for
    previews of commands taken from configuration, which do not require trust.
*)

val render_command : argument list -> string

(* POSIX shell representation; symbolic IDs are explicitly marked placeholders
   and a {!Redacted} argument is shown as its [shown] text, never its actual
   value. *)
val render_multiline : argument list -> string
(** Indented POSIX shell command with continuations between argument groups. *)

val render_steps : string list -> string
(** Number the steps from 1 in order, one per line group: each step is prefixed
    with ["N. "] and followed by a newline. Steps may span several lines. *)

val quote : string -> string
(** Quote a literal argument for POSIX shell display. *)
