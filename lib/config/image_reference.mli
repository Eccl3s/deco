val check_name : string -> (unit, string) result
(** Pure ASCII image syntax checks; no normalization or runtime lookup. *)

val check_tag : string -> (unit, string) result
