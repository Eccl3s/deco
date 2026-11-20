(** Listing of Deco-managed containers for [deco list].

    Labels are reported as recorded: no ownership verification is performed, so
    an entry is not proof that Deco created the container. *)

type entry = {
  project : string option;  (** [dev.deco.project], if present. *)
  project_root : string option;  (** [dev.deco.project-root], if present. *)
  container : string option;  (** The container's first Podman name. *)
  container_id : string;  (** Full container ID. *)
  state : string;  (** Podman's state as reported, not normalised. *)
  image : string option;  (** Image reference recorded at creation. *)
  image_id : string option;  (** Full image ID. *)
}

val of_container : Podman.listed_container -> entry

val sort : entry list -> entry list
(** Order by project, then container name, then container ID. Comparison is
    byte-wise and missing values sort after present ones. *)

val render_human : entry list -> string
(** A bordered table of project, container, state, image and project root, or a
    one-line message when there are no entries. Missing and empty values are
    shown as ["-"]. Control characters, invalid UTF-8 and bidirectional
    formatting characters are escaped, so values cannot inject terminal
    sequences. The output never contains ANSI styling and ends with a newline.
*)

val render_json : entry list -> string
(** A JSON array of entries followed by one newline. Missing values are [null].
*)

val run : ?run:Podman.runner -> unit -> (entry list, Podman.error) result
(** Check that Podman is available, then list managed containers sorted with
    {!sort}. No printing or exit-code mapping. *)
