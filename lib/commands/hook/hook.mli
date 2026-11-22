(** Lifecycle hooks ([specs/deco-config.md] §8, [specs/deco-cli.md] §6).

    Every hook runs the same way: [<container.shell> -lc <command>] through
    [podman exec] in the selected container, as the configured user and in
    [container.workdir], without a TTY or stdin, with both output streams sent
    to Deco's stderr so they stream to the terminal without mixing into Deco's
    stdout (for example the output of [deco exec]). Callers decide when a hook
    runs; they run it only on an owned, compatible container after their
    existing checks. *)

type name = Post_create | Post_start | Pre_enter | Pre_stop

val to_string : name -> string
(** The configuration key, such as ["post_start"]. *)

val configured : Config_loader.t -> name -> string option
(** The configured command, or [None] when the hook is not set. *)

val command : Config_loader.t -> name -> Command_plan.argument list option
(** The [podman exec] argument vector for a configured hook, with the container
    as a {!Command_plan.Container_id} placeholder. Validation has already
    rejected NUL bytes in hook commands. *)

val render_step :
  condition:string -> name -> Command_plan.argument list -> string
(** A dry-run step for {!Command_plan.render_steps}:
    ["<condition>, run the <hook> hook:"] followed by the indented command, with
    its arguments escaped by {!Command_plan.escape_literals} because previews do
    not require trust. *)

type runner = string list -> (Process.result, Process.error) result

type failure =
  | Exited of { hook : name; status : Unix.process_status }
      (** The hook ran and exited nonzero or was terminated by a signal. *)
  | Launch of { hook : name; error : Process.error }
      (** The hook command could not be run at all. *)

val failed : failure -> name
(** The hook that failed. *)

val failure_message : failure -> string
(** A one-line description, such as
    ["post_start hook failed with exit status 7"]. *)

val exit_status : failure -> int
(** The status Deco exits with: the hook's own exit status when it exited
    normally, otherwise [1]. *)

val run :
  ?run:runner ->
  Config_loader.t ->
  container_id:string ->
  name ->
  (unit, failure) result
(** Run the hook in [container_id] and wait for it. An unconfigured hook
    succeeds without running anything. The default runner sends the hook's
    output to stderr ({!Process.To_stderr}) and forwards signals. A nonzero exit
    status is a failure. *)
