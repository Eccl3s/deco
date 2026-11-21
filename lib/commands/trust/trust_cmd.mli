(** [deco trust] ([specs/deco-trust.md] §7): review and approve a project's
    configuration, show its trust state, or revoke its approvals. Normal output
    goes to [out] and warnings to [err]; failures are returned for the caller to
    report and map to exit codes. *)

type mode =
  | Approve of { yes : bool; dry_run : bool }
      (** Review, then approve with [yes] or an interactive confirmation.
          [dry_run] stops after the review. *)
  | Show  (** Print the trust state without the review or a prompt. *)
  | Revoke  (** Remove every approval for the project root. *)

type error =
  | Trust of Trust.error  (** The digest or trust store location failed. *)
  | Not_interactive
      (** No [--yes], and stdin and stdout are not both terminals. *)
  | Declined  (** The confirmation prompt was not answered [y] or [yes]. *)
  | Changed_during_review
      (** [.deco/] changed between the review and recording the approval. *)
  | Store of string  (** The trust store could not be written. *)

val run :
  ?store_dir:string ->
  ?now:(unit -> float) ->
  ?interactive:bool ->
  ?prompt:(string -> string option) ->
  ?out:(string -> unit) ->
  ?err:(string -> unit) ->
  deco_version:string ->
  mode ->
  Config_loader.t ->
  (unit, error) result
(** [store_dir] defaults to {!Trust_store.dir}, [now] to [Unix.gettimeofday],
    [out] and [err] to stdout and stderr. [interactive] (default [false]) says
    whether stdin and stdout are terminals. [prompt question] shows [question]
    and returns the answer, or [None] at end of input; the default writes to
    stdout and reads a line from stdin. Store warnings go to [err], prefixed
    with ["deco: "].

    [Approve] prints ["Configuration is already trusted: <root>"] when it is,
    and otherwise the {!Trust_review} review. With [yes] or a confirmed prompt
    it computes the digest again, refuses if it differs from the reviewed one,
    records the approval and prints ["Trusted <root>"]. The configuration file's
    parsed bytes are what was reviewed, so they are what is approved.

    [Show] prints the state, root, current digest, the most recent approval's
    time or [-], and any changes. [Revoke] prints ["Trust revoked: <root>"] or
    ["Configuration was not trusted: <root>"]. Roots are escaped with
    {!Terminal_text.escape}. *)

val error_to_string : error -> string
(** A one-line description, without a ["deco: "] prefix. *)
