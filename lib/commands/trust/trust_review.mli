(** The review [deco trust] prints before asking for approval
    ([specs/deco-trust.md] §7): the trust state, what changed, and a summary of
    the security-relevant settings this version of Deco applies. Pure; nothing
    is read or printed. *)

val render : now:float -> Trust.status -> Config_loader.t -> string
(** Sections for the project and its trust state, changed entries (only when
    there are some), the build, image, container and mounts, and the planned
    settings that are accepted but not applied, in that order. A build context
    outside the canonical [.deco/] directory ([status.deco_dir]) and a workspace
    source outside the project root are flagged. Build arguments are listed by
    name only. Every value is escaped with {!Terminal_text.escape}; the output
    has no styling and ends with a newline. Times use {!Timestamp.to_human}
    relative to [now]. *)
