type t = Exec_plan.t
(** Pure shell planning; no terminal detection, filesystem access, or Podman
    calls. *)

val make : Config_loader.t -> (t, string) result
(** Plan interactive TTY entry using the configured shell as one executable
    argument. Reuse exec's user, workdir, and NUL-byte validation. *)

val render : t -> string
(** Describe conditional startup, verification, the [post_start] hook after a
    start, and shell entry. *)
