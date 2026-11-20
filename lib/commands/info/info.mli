(** The report behind [deco info]: the project's resolved configuration and the
    state of its Podman resources, gathered with read-only queries. Nothing here
    mutates resources or prints. Reporting a resource as owned or compatible is
    informational only; commands that use it verify it again. *)

type project = {
  name : string;
  description : string option;
  root : string;  (** Canonical project root. *)
  config : string;  (** Path of [.deco/config.toml]. *)
}

type podman = {
  available : bool;
  version : string option;  (** [None] when Podman is unavailable. *)
}

type image = {
  name : string;
  tag : string;
  id : string option;  (** Full ID; [None] when the image does not exist. *)
  exists : bool option;  (** [None] when Podman is unavailable. *)
  created : float option;
      (** Seconds since the epoch; [None] when absent or unparseable. *)
  owned : bool option;
      (** Whether the project's ownership labels are present; [None] when the
          image does not exist or Podman is unavailable. *)
}

type container = {
  name : string;
  id : string option;
  exists : bool option;
  state : string option;
      (** [running], [stopped], [paused] or [unknown]; see {!state_of_podman}.
      *)
  podman_state : string option;  (** The state exactly as Podman reports it. *)
  created : float option;
  owned : bool option;
  compatible : bool option;
      (** Evaluated only when the image and container both exist and are owned.
      *)
  incompatibilities : string list;
      (** Each mismatch; empty when compatible or not evaluated. *)
}

type runtime = {
  user_mode : string;  (** [image] or [keep-id]. *)
  workdir : string option;
      (** The configured workdir, else the inspected image's, else [None]. *)
  shell : string;
}

type mount = {
  source : string;  (** Host path, or ["-"] for source-less mounts. *)
  target : string;
  kind : string;  (** Mount type, such as ["bind"]. *)
  readonly : bool;
  relabel : string;  (** [shared], [private] or [none]. *)
}

type port = { host : int; container : int; protocol : string; bind : string }

type report = {
  project : project;
  podman : podman;
  image : image;
  container : container;
  runtime : runtime;
  mounts : mount list;
  dns : string list;
  ports : port list;
  hooks : string list;
  actions : string list;
}
(** [dns], [ports], [hooks] and [actions] are always empty until those settings
    are implemented. *)

val state_of_podman : string -> string
(** Simplify a Podman state: [running] stays [running]; [created], [configured],
    [exited] and [stopped] are [stopped]; [paused] stays [paused]; anything else
    is [unknown]. *)

val collect :
  ?run:Podman.runner ->
  ?read_many:(string list list -> (Process.result, Process.error) result list) ->
  ?probe:(unit -> bool option) ->
  Config_loader.t ->
  (report * string option, Podman.error) result
(** Build the report. Podman's version and both inspections are batched like
    {!Container_runtime.preflight}; SELinux is detected only when it decides a
    mismatch, using [probe] for local status. When Podman is unavailable the
    result is still [Ok], with every Podman-derived field unknown and the reason
    alongside. Any other Podman failure is [Error]. *)

val render_json : report -> string
(** The spec's JSON shape, followed by one newline. Every field is present:
    unknown values are [null] and timestamps are UTC RFC 3339 with second
    precision. *)
