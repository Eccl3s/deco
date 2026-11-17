type outcome = { container_id : string; stopped : bool }
(** [stopped] means a stop was performed and verified. *)

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string

type error = { cause : cause; stop_completed : bool }
(** [stop_completed] records successful Podman stop, even if verification fails.
*)

val run : ?run:Podman.runner -> Config_loader.t -> (outcome, error) result
(** Stop only an owned running container, by inspected ID. No printing, exit
    mapping, hooks, or signal handling; callers may supply a signal-aware
    runner. *)
