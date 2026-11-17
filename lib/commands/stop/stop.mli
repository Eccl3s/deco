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

val run :
  ?run:Podman.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?container_id:string ->
  ?check_availability:bool ->
  Config_loader.t ->
  (outcome, error) result
(** Stop only an owned running container, by inspected ID. [container_id]
    selects an explicit ID instead of the configured name. No printing, exit
    mapping, hooks, or signal handling; callers may supply a signal-aware
    runner. [check_availability] defaults to [true]; callers may set it to
    [false] after checking the same runtime within the current operation.
    [read_many] batches initial availability and inspection only; it is unused
    when [check_availability] is false. Ownership, state, and post-stop
    verification always run. *)
