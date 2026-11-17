(** Interactive shell entry through exec's existing lifecycle orchestration. *)
val run :
  ?execute:Exec.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  Config_loader.t ->
  tty:bool ->
  (Exec.outcome, Exec.error) result
(** Callers derive [tty] from both stdin and stdout and provide signal-aware
    runners when required. A false value fails before any runner or probe call.
    Preserve shell termination status and startup progress; never stop or remove
    the container on return. No terminal detection, printing, or exit mapping.
*)
