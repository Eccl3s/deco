(** Run a configured action ([specs/deco-cli.md] §[deco run]) through
    {!Exec.run}, so preparation, the [post_start] hook after a start, TTY
    handling and status passthrough match [deco exec]. *)

type error =
  | Unknown_action of string  (** No action with this name is configured. *)
  | Exec of Exec.error  (** Planning, preparation or execution failed. *)

val run :
  ?execute:Exec.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  ?hook:Hook.runner ->
  Config_loader.t ->
  tty:bool ->
  string ->
  (Exec.outcome, error) result
(** Plan the named action with {!Run_plan.make}, then execute it with
    {!Exec.run}. An unknown action invokes no runner. A planning failure is
    [Exec { cause = Planning _; started = false }]. No printing or exit mapping.
*)
