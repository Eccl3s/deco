(** The review [deco trust] prints before asking for approval
    ([specs/deco-trust.md] §7): the trust state, what changed, and a summary of
    the security-relevant settings this version of Deco applies. Pure; nothing
    is read or printed. *)

val render : now:float -> Trust.status -> Config_loader.t -> string
(** Sections for the project and its trust state, changed entries (only when
    there are some), the build, image, container, mounts and hooks, and the
    planned settings that are accepted but not applied, in that order. A build
    context outside the canonical [.deco/] directory ([status.deco_dir]) and a
    workspace source outside the project root are flagged. Build arguments are
    listed by name only. Every configured hook command is shown in full, in
    execution order. Planned settings are listed with their values from the
    parsed configuration bytes, so actions appear in full, except
    environment-variable values, which are shown as [(hidden)]. Every value is
    escaped with {!Terminal_text.escape}; the output has no styling and ends
    with a newline. Times use {!Timestamp.to_human} relative to [now]. *)
