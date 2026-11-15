type runner =
  Process.output -> string list -> (Process.result, Process.error) result
(** Assemble a successfully loaded project. Failures retain managed resources.
*)

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string

type error = { cause : cause; completed : string list }

type outcome = {
  image_id : string;
  container_id : string;
  created : bool;
  started : bool;
}

val compatibility :
  Config_loader.t -> Podman.image -> Podman.container -> (unit, string) result

val run : ?execute:runner -> Config_loader.t -> (outcome, error) result
