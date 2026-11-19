(** Direct argument-vector execution. Captured streams use temporary files to
    avoid pipe deadlocks; files and descriptors are cleaned on return. *)
type output = Capture | Inherit

type result = { status : Unix.process_status; stdout : string; stderr : string }

type error = { operation : string; message : string }
(** A program that cannot be started is reported as operation ["launch"] with a
    message naming it, such as ["podman: command not found"] or
    ["podman: permission denied"]. Other failures name the system call. *)

val not_found : error -> bool
(** Whether the program could not be started because it does not exist. *)

val run :
  ?output:output ->
  ?poll:(unit -> unit) ->
  ?forward_signals:bool ->
  string list ->
  (result, error) Stdlib.result

val run_stream :
  on_chunk:(string -> unit) ->
  poll:(unit -> unit) ->
  string list ->
  (result, error) Stdlib.result
(** Stream merged stdout/stderr with periodic polling; stdin is /dev/null. After
    the direct child exits, drain for at most one second, even if a descendant
    retains the pipe. Later descendant output is discarded. The direct child is
    reaped once; descendants are never killed by the runner. *)

val run_many :
  ?poll:(unit -> unit) ->
  ?forward_signals:bool ->
  string list list ->
  (result, error) Stdlib.result list
(** Launch captured commands concurrently, returning results in input order. *)
