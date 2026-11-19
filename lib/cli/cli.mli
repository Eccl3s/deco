module Argv = Argv
(** Argument pre-processing, exposed for testing. *)

val run : unit -> int
(** Evaluate process arguments, write CLI output, and return an exit status.
    Applies the plain-output environment setup without exiting the process. *)
