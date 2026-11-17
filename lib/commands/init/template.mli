type t = {
  name : string;
  description : string;
  config_template : string;
  containerfile : string;
}
(** Embedded Containerfiles are preserved verbatim; no runtime source-tree
    access. *)

val all : t list
val find : string -> t option
val project_name : string -> string
val render : t -> basename:string -> string
