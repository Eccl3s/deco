(** The trust digest of [specs/deco-trust.md] §3: a BLAKE2b-256 digest over a
    project's [.deco/] directory, plus the configuration file and Containerfile
    when they resolve outside it. Reading the filesystem is the only effect;
    nothing is written. *)

type entry = {
  path : string;
      (** Relative to the canonical [.deco/] directory with [/] separators, or
          canonical and absolute for a file outside it. *)
  digest : string;  (** Digest of this entry's record alone. *)
}

type t = {
  digest : string;  (** [blake2b-256:] followed by lowercase hexadecimal. *)
  entries : entry list;  (** Sorted byte-wise by [path]. *)
}

type error =
  | Unsupported_entry of string
      (** A FIFO, socket or device node, named by its path. *)
  | Filesystem of string  (** A path could not be resolved, listed or read. *)

val compute :
  deco_dir:string ->
  config:string * string ->
  containerfile:string ->
  (t, error) result
(** [compute ~deco_dir ~config:(config_path, contents) ~containerfile] walks
    [deco_dir] after resolving it, without following symlinks beneath it.
    Directories contribute their path, regular files their path and contents,
    and symlinks their path and target. [contents] are the configuration bytes
    that were parsed: they stand in for the configuration file wherever it
    resolves, so it is never read again. A configuration file or [containerfile]
    resolving outside [deco_dir] adds a record keyed by its canonical path; one
    record when both resolve to the same file. Records are length-prefixed, so
    distinct inputs cannot produce the same stream. *)

val relative_to : dir:string -> string -> string option
(** [relative_to ~dir path] is [path] relative to [dir] when [path] lies
    strictly beneath it, comparing canonical paths textually; [None] otherwise.
    A [dir] of ["/"] contains every other absolute path. *)

type change = Added | Modified | Removed

val diff : approved:entry list -> current:entry list -> (string * change) list
(** Entries whose path appears only in [current] ([Added]), only in [approved]
    ([Removed]), or in both with different digests ([Modified]), sorted
    byte-wise by path. *)

val change_to_string : change -> string
(** [added], [modified] or [removed]. *)

val error_to_string : error -> string
