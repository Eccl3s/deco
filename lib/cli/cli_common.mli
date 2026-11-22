(** Shared terms, exit codes and helpers for the Cmdliner subcommands. *)

(** How a project command selects its project. *)
type selection =
  | Discover  (** Search the current directory and its parents. *)
  | Directory of string  (** [--project-dir PATH], without parent fallback. *)
  | Named of string  (** [-p, --project NAME], located by Podman labels. *)

val project : selection Cmdliner.Term.t
(** The [--project-dir] and [-p, --project] options of every project command.
    Supplying both, or an empty name, is a usage error. *)

type format = [ `Human | `Json ]

val format : doc:string -> format Cmdliner.Term.t
(** The [--format human|json] option of informational commands, defaulting to
    [human]. [doc] describes what each format produces for the command. *)

val exits : Cmdliner.Cmd.Exit.info list

val load_project : selection -> (Deco.Config_loader.t, int) result
(** Select and load the project, printing any error to stderr and returning its
    exit code. Discovery or selection problems and invalid configuration are
    [2]. Named selection queries Podman read-only first: Podman unavailable is
    [3], other Podman failures are [1], and an unmatched, ambiguous, unusable or
    mismatched project is [2]. The returned configuration is always validated;
    callers still verify resource ownership before any mutation. *)

val load_trusted_project :
  ?no_hooks:bool ->
  command:string ->
  dry_run:bool ->
  selection ->
  (Deco.Config_loader.t, int) result
(** {!load_project}, then require the [trusted] state ([specs/deco-trust.md] §6)
    for [deco <command>]. Store warnings are printed. When the project is not
    trusted, print {!Deco.Trust.failure_message} and return [5], or, for a dry
    run, print {!Deco.Trust.dry_run_note} and continue. A digest that cannot be
    computed is [2], dry run or not. Nothing is prompted.

    [no_hooks] (default [false]) is [stop] and [remove]'s [--no-hooks]: a
    configuration that is not trusted is then allowed, with
    {!Deco.Trust.no_hooks_warning} instead of a failure or the dry-run note. *)

val report_execution_result : (Deco.Exec.outcome, Deco.Exec.error) result -> int
