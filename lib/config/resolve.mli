(** Pure default resolution after core validation. Host identities remain
    symbolic and host paths remain literal. Success does not establish
    filesystem validity, runtime compatibility, or image-reference validity.
    Explicit and derived container names are checked. *)
val apply : Config_types.t -> (Effective.t, Validate.error list) result
(** Return validation errors unchanged, or construct an effective configuration
    without modifying the input. No user build arguments are generated here.
    Effective values do not retain whether a setting was explicit or defaulted;
    retain the decoded configuration alongside them when provenance is needed.
*)
