type runner = string list -> (Process.result, Process.error) result
(** Read-only Podman operations. No functions print or assign CLI exit codes.

    Process failures are mapped consistently: the availability probes
    ({!available} and {!info}) report any failure as [Unavailable], because
    their purpose is to decide whether Podman is usable. Other operations report
    a failure to launch Podman as [Unavailable] and any other process failure,
    such as capturing output, as [Runtime]. *)

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

val unavailable : Process.error -> error
(** Describe a failure to run Podman at all. A missing program gets a plain
    explanation; other launch failures keep the reason. *)

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

type listed_container = {
  id : string;  (** Full container ID. *)
  names : string list;
  state : string;  (** Podman's state as reported, such as ["exited"]. *)
  image : string option;
      (** Image reference recorded at creation; [None] when Podman reports none,
          as for rootfs-based containers. *)
  image_id : string option;
      (** Full image ID; [None] when Podman reports none. *)
  labels : labels;
}

val list_managed_containers :
  ?run:runner -> unit -> (listed_container list, error) result
(** List all containers labelled [dev.deco.managed=true], including non-running
    ones. A failure to launch Podman is [Unavailable]; malformed entries,
    including an empty ID, fail the whole listing instead of being omitted. *)
