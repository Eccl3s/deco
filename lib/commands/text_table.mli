(** Framed plain-text tables for human output, drawn with printbox. *)

val render : header:string list -> string list list -> string
(** A framed table with the [header] row, one rule under it, and then the
    [rows], each with one cell per header column. Cells must be single-line,
    already escaped text (for example with {!Terminal_text.escape}); a newline
    in a cell would misalign the rows. The output has no styling and ends with a
    newline. *)
