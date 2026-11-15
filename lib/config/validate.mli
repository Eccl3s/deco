type error = Diagnostic.t = { path : string list; message : string }
(** Partial, pure semantic validation. Success does not imply readiness for
    container operations. No defaults are applied and inputs are unchanged.

    Explicit and derived container names are checked. Image repository and tag
    syntax are checked (IPv6 registries are unsupported). UID/GID bounds are
    checked; image mode forbids UID/GID as a v0.1.0 restriction. Host path
    expansion and filesystem checks are separate. Build stages, image accounts,
    executables, SELinux and runtime compatibility are not checked here. *)

val valid_id : int -> bool
(** Check numeric bounds 0-4294967294 only. Inputs must already fit an OCaml
    int. Does not check account existence or namespace mapping feasibility. *)

val check : Config_types.t -> (unit, error list) result
(** Collect independent core-rule errors, sorted by path and message. An error
    result is always nonempty. *)

val error_to_string : error -> string
