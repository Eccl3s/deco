module Argv = Argv
(** Argument pre-processing, exposed for testing. *)

val run : unit -> int
(** Evaluate process arguments, write CLI output, and return an exit status.
    Help and parser diagnostics written to a non-terminal contain no ANSI
    styling. Does not exit the process. *)
