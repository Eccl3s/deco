type operation =
  | Availability
  | Image_inspect
  | Container_inspect
  | Build
  | Built_inspect
  | Create
  | Created_inspect
  | Start
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
  post_create : argument list option;
      (** The configured [post_create] hook; [None] when it is not set. *)
  post_start : argument list option;
      (** The configured [post_start] hook; [None] when it is not set. *)
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
(** The ordered workflow: inspection, build, create and start, then the
    configured [post_create] (on a container's first start) and [post_start]
    (after a creation or start) hooks. *)
