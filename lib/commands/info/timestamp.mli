(** Creation times for [deco info]: parsing Podman's RFC 3339 timestamps and
    formatting them in UTC. Times are seconds since the Unix epoch. *)

val parse : string -> float option
(** Parse an RFC 3339 date-time such as ["2026-11-20T08:39:25.440792071Z"] or
    ["2026-11-20T09:39:25+01:00"], keeping any fractional seconds. The offset is
    required. [None] when the text is malformed or a field is out of range. *)

val to_rfc3339 : float -> string
(** UTC with second precision, truncating fractions: ["2026-11-20T08:39:25Z"].
*)

val to_human : now:float -> float -> string
(** UTC to the minute with the age relative to [now]:
    ["2026-11-11 09:14 UTC (9 days ago)"]. An age under a minute either way is
    ["just now"]; a time more than a minute after [now] is ["in the future"]. *)
