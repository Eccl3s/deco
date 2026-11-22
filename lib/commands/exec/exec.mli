type runner =
  Process.output -> string list -> (Process.result, Process.error) result
(** Execute in an existing owned, compatible environment; never build or create.
*)

type cause = Start.cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Hook of Hook.failure

type error = Start.error = { cause : cause; started : bool }
(** Shared with {!Start}: preparation is {!Start.run}. *)

type outcome = {
  container_id : string;
  started : bool;
  status : Unix.process_status;
}

val run :
  ?execute:runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  ?hook:Hook.runner ->
  ?before_exec:(container_id:string -> (unit, Hook.failure) result) ->
  Config_loader.t ->
  tty:bool ->
  string list ->
  (outcome, error) result
(** Prepare with {!Start.run}, which runs [post_start] with [hook] when it
    starts a stopped container, then call [before_exec] with the verified
    container (a failure prevents the command), then execute the command.
    Preserve command termination status, including nonzero exits. Startup is
    retained after subsequent failure, including a failed hook. No printing,
    exit mapping, or signal forwarding. *)
