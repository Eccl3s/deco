(** Pure planning from a successfully loaded configuration; no runtime queries.
*)
type argument = Literal of string | Image_id | Container_id

type step = { condition : string option; command : argument list }

type t = private {
  build : string list;
  create : argument list;
  steps : step list;
}

type error = string

val make : Config_loader.t -> (t, error) result

val resolve :
  image_id:string -> container_id:string -> argument list -> string list

(* Substitute inspected resource IDs into a command template. *)
val render_command : argument list -> string

(* POSIX shell representation; symbolic IDs are explicitly marked placeholders. *)
val render : t -> string
