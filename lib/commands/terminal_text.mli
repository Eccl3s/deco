(** Making untrusted text safe to print to a terminal. *)

val escape : string -> string
(** Escape C0 and C1 control characters, bidirectional formatting characters
    (U+200E, U+200F, U+202A–U+202E, U+2066–U+2069) and invalid UTF-8 bytes, so
    the text cannot inject terminal sequences or reorder what is shown.
    Characters up to U+00FF and invalid bytes become [\xNN]; others become
    [\u{NNNN}]. All other text, including valid non-ASCII UTF-8, is kept. *)
