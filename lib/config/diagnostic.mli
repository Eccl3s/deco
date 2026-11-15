type t = { path : string list; message : string }
(** Shared path-based configuration diagnostics. *)

val compare : t -> t -> int
(** Order lexicographically by path components, then message. *)

val to_string : t -> string
(** Render a dotted path, quoting non-bare components, followed by the message.
    An empty path renders only the message. *)

val format_path : string list -> string
(** Render quoted dotted components; the empty path renders an empty string. *)
