(** TOML decoding of supported and recognized planned settings without defaults
    or semantic validation. *)

type error =
  | Syntax_error of { message : string; location : (int * int) option }
  | Schema_error of Diagnostic.t

val from_string : string -> (Config_types.t, error list) result
(** Collect independent schema errors, sorted by path. Syntax errors stop
    decoding. Known parser failures are returned as syntax errors; unexpected
    programming exceptions are not suppressed. *)

val error_to_string : error -> string

val from_string_with_ignored :
  string -> (Config_types.t * string list list, error list) result

val project_name : string -> string option
(** The [project.name] string, if the input is syntactically valid TOML and has
    one. Unlike {!from_string} this ignores every other key, so a configuration
    with schema errors can still be identified. *)
