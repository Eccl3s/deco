type runner =
  Process.output -> string list -> (Process.result, Process.error) result
(** Execute in an existing owned, compatible environment; never build or create.
*)

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string

type error = { cause : cause; started : bool }

type outcome = {
  container_id : string;
  started : bool;
  status : Unix.process_status;
}

val run :
  ?execute:runner ->
  Config_loader.t ->
  tty:bool ->
  string list ->
  (outcome, error) result
(** Preserve command termination status, including nonzero exits. Startup is
    retained after subsequent failure. No printing, exit mapping, or signal
    forwarding. *)
