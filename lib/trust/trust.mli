(** The trust state of a loaded project ([specs/deco-trust.md] §5), and the
    messages commands print about it. Computing the state reads the project's
    [.deco/] directory and the trust store; nothing is written or printed. *)

type state =
  | Trusted  (** The current digest matches an approval. *)
  | Changed  (** A record exists, but no approval matches. *)
  | Untrusted  (** No usable record exists. *)

type status = {
  state : state;
  root : string;  (** Canonical project root. *)
  deco_dir : string;
      (** Canonical [.deco/] directory: the one the digest walked, resolved when
          [.deco] is a symlink. *)
  digest : Trust_digest.t;  (** The current trust digest. *)
  trusted_at : float option;
      (** The matching approval's time when [Trusted], the most recent
          approval's when [Changed], and [None] when [Untrusted]. *)
  changes : (string * Trust_digest.change) list;
      (** Entries that differ from the most recent approval; empty unless
          [Changed]. *)
  warnings : string list;  (** Why an unusable record was ignored. *)
}

type error =
  | Digest of Trust_digest.error
  | Store of string  (** The trust store could not be located or written. *)

val check : ?store_dir:string -> Config_loader.t -> (status, error) result
(** Digest [.deco/] using the loaded configuration bytes and the resolved
    Containerfile, then compare it with the project's record in [store_dir]
    (default {!Trust_store.dir}). *)

val approve :
  ?store_dir:string ->
  deco_version:string ->
  now:float ->
  Config_loader.t ->
  (unit, error) result
(** Digest [.deco/] as {!check} does and record an approval of it in [store_dir]
    (default {!Trust_store.dir}) with {!Trust_store.approve}. No review is
    shown; [deco init] uses this for the configuration it has just written. *)

val state_to_string : state -> string
(** [trusted], [changed] or [untrusted]. *)

val render_changes : (string * Trust_digest.change) list -> string list
(** One line per change, such as ["  modified  config.toml"], with paths escaped
    by {!Terminal_text.escape}. *)

val failure_message : command:string -> status -> string
(** The stderr message for a [command] refused because [status] is not
    [Trusted]: the state, the escaped root, any changes, and the instruction to
    run [deco trust]. For [stop] and [remove] it also mentions [--no-hooks].
    Each line ends with a newline; the first starts with ["deco: "]. *)

val dry_run_note : command:string -> string
(** The stderr note for a dry run of [command] when the configuration is not
    trusted, ending with a newline. *)

val error_to_string : error -> string
