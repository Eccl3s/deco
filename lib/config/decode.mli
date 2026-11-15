(** Strict TOML decoding without defaults or semantic validation. *)

type error =
  | Syntax_error of { message : string; location : (int * int) option }
  | Schema_error of Diagnostic.t

val from_string : string -> (Config_types.t, error list) result
(** Collect independent schema errors, sorted by path. Syntax errors stop
    decoding. Known parser failures are returned as syntax errors; unexpected
    programming exceptions are not suppressed. *)

val error_to_string : error -> string
