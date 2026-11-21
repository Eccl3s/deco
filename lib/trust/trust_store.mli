(** The per-user trust store of [specs/deco-trust.md] §4: one JSON record of
    approvals per canonical project root. Records are only written by {!approve}
    and removed by {!revoke}; reading never changes the store. *)

type approval = {
  digest : string;  (** The approved {!Trust_digest.t} digest. *)
  trusted_at : float;
      (** Seconds since the epoch, truncated to whole seconds. *)
  deco_version : string;  (** The Deco version that recorded the approval. *)
  entries : Trust_digest.entry list;
      (** Per-entry digests, for reporting changes. *)
}

type record = {
  project_root : string;
  project_name : string;  (** Informational; never used for matching. *)
  approved : approval list;  (** Most recent first. *)
}

val max_approvals : int
(** Approvals kept per project root: 16. *)

val dir : ?getenv:(string -> string option) -> unit -> (string, string) result
(** [$XDG_STATE_HOME/deco/trust] when [XDG_STATE_HOME] is absolute, else
    [$HOME/.local/state/deco/trust], with the passwd entry's home when [HOME] is
    unset or not absolute. [getenv] defaults to [Sys.getenv_opt]. An error when
    no absolute home can be found. Nothing is created. *)

val record_path : dir:string -> root:string -> string
(** [dir/<BLAKE2b-256 of root, hex>.json]. *)

val read : dir:string -> root:string -> record option * string option
(** The record for [root], or [None] when there is none. A record that cannot be
    read or parsed, has an unsupported [version], or whose [project_root] is not
    [root] is treated as absent, and the second component explains why. The file
    is left as it is. *)

val approve :
  dir:string ->
  root:string ->
  name:string ->
  deco_version:string ->
  now:float ->
  Trust_digest.t ->
  (unit, string) result
(** Record an approval of the digest for [root], replacing an unusable record.
    An approval with the same digest moves to the front; at most
    {!max_approvals} are kept, dropping the oldest. Missing directories are
    created with mode [0700]. The record is written to a [0600] temporary file
    in [dir], synced, and renamed into place. *)

val revoke : dir:string -> root:string -> (bool, string) result
(** Delete the record for [root]. [Ok false] when there was none. *)
