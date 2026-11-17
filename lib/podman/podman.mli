type runner = string list -> (Process.result, Process.error) result
(** Read-only Podman operations. No functions print or assign CLI exit codes. *)

type error =
  | Unavailable of string
  | Runtime of { operation : string; message : string }
  | Invalid_response of { operation : string; message : string }

type 'a presence = Absent | Present of 'a
type labels = (string * string) list
type image = { id : string; labels : labels; user : string; workdir : string }

type mount = {
  kind : string;
  source : string;
  destination : string;
  options : string list;
}

type container = {
  id : string;
  labels : labels;
  state : string;
  image_id : string;
  user : string;
  userns : string;
  workdir : string;
  init : bool;
  mounts : mount list;
}

val available : ?run:runner -> unit -> (unit, error) result
val inspect_image : ?run:runner -> string -> (image presence, error) result

val inspect_container :
  ?run:runner -> string -> (container presence, error) result

val message : Process.result -> string
val decode_image : string -> (image, string) result
val decode_container : string -> (container, string) result

val info : ?run:runner -> unit -> (string, error) result
(** Check availability and return the raw Podman info response. *)

type container_summary = { id : string; image_id : string; names : string list }

val list_containers :
  ?run:runner -> unit -> (container_summary list, error) result
(** List all Podman containers with full IDs, including non-running ones.
    Malformed summaries fail instead of omitting possible dependents. *)
