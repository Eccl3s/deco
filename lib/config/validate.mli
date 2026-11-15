type error = Diagnostic.t = { path : string list; message : string }
(** Partial, pure semantic validation. Success does not imply readiness for
    container operations. No defaults are applied and inputs are unchanged.

    Explicit and derived container names are checked. Image repository and tag
    syntax are checked (IPv6 registries are unsupported). UID/GID bounds, host
    path expansion and filesystem checks are deferred. Build stages, image
    accounts, executables, SELinux and runtime compatibility are not checked
    here. *)

val check : Config_types.t -> (unit, error list) result
(** Collect independent core-rule errors, sorted by path and message. An error
    result is always nonempty. *)

val error_to_string : error -> string
