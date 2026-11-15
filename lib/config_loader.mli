type t = {
  project : Project.t;
  source : Config.t;
  effective : Config.Effective.t;
  host_paths : Host_paths.t;
}
(** Load an already selected project without rediscovery. Success includes
    decoding, core validation, defaults, and host-path resolution and filesystem
    checks. Image references, numeric identities, and runtime compatibility
    remain deferred. Filesystem checks reflect current state, not future
    availability; success does not establish readiness for container operations.
*)

type error =
  | Read_error of { config_path : string; message : string }
  | Decode_errors of { config_path : string; errors : Config.Decode.error list }
  | Validation_errors of {
      config_path : string;
      errors : Config.Validate.error list;
    }
  | Host_path_errors of {
      config_path : string;
      errors : Config.Diagnostic.t list;
    }

val load : ?home_dir:string -> Project.t -> (t, error) result
(** Read once, close reliably, decode, then resolve defaults with core
    validation, then resolve and check host paths. Forward the optional home
    override to [Host_paths.resolve], which performs lazy default home lookup.
    Retain the supplied project and decoded omissions. Known read failures
    become errors; unexpected programming exceptions are not suppressed.
    Read-error messages have one exact leading config-path prefix removed when
    present; other messages are preserved. *)

val error_to_string : error -> string
(** Prefix each diagnostic with its config path; join diagnostics with newlines.
    Does not print or assign CLI exit codes. *)
