val pp_config_error : Format.formatter -> Deco.Config_loader.error -> unit
(** Group loader diagnostics under a stage-specific heading and filename, with
    aligned plain-text rows. The caller supplies the final newline. *)
