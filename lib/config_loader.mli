type t = {
  project : Project.t;
  source : Config.t;
  effective : Config.Effective.t;
}
(** Load an already selected project without rediscovery or path resolution.
    Success means decoded, core-validated and default-filled, not ready for
    container operations. Filesystem validation of configured paths, image
    references, numeric identities and runtime checks remain deferred. *)

type error =
  | Read_error of { config_path : string; message : string }
  | Decode_errors of { config_path : string; errors : Config.Decode.error list }
  | Validation_errors of {
      config_path : string;
      errors : Config.Validate.error list;
    }

val load : Project.t -> (t, error) result
(** Read once, close reliably, decode, then resolve defaults with core
    validation. Retain the supplied project and decoded omissions. Known read
    failures become errors; unexpected programming exceptions are not
    suppressed. Read-error messages have one exact leading config-path prefix
    removed when present; other messages are preserved. *)

val error_to_string : error -> string
(** Prefix each diagnostic with its config path; join diagnostics with newlines.
    Does not print or assign CLI exit codes. *)
