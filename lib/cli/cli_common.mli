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

val report_execution_result : (Deco.Exec.outcome, Deco.Exec.error) result -> int
