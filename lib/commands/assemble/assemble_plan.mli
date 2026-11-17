type operation =
  | Availability
  | Image_exists
  | Image_inspect
  | Container_exists
  | Container_inspect
  | Build
  | Built_exists
  | Built_inspect
  | Create
  | Created_exists
  | Created_inspect
  | Start
  | Started_exists
  | Started_inspect
      (** Pure planning from a successfully loaded configuration; no runtime
          queries. *)

type argument = Command_plan.argument =
  | Literal of string
  | Image_id
  | Container_id

type step = {
  operation : operation;
  condition : string option;
  command : argument list;
}

type t = private {
  image_name : string;
  container_name : string;
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
val render_multiline : argument list -> string
(** Indented POSIX shell command with continuations between argument groups. *)

val render : t -> string
