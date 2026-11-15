(** Direct argument-vector execution. Captured streams use temporary files to
    avoid pipe deadlocks; files and descriptors are cleaned on return. *)
type output = Capture | Inherit

type result = { status : Unix.process_status; stdout : string; stderr : string }
type error = { operation : string; message : string }

val run : ?output:output -> string list -> (result, error) Stdlib.result
