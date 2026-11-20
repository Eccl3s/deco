val command : int Cmdliner.Cmd.t
(** [deco info]: report the project's configuration and Podman resource state.
    Exits [0] with a full report, [3] with a full report when Podman is
    unavailable, [1] without a report on any other Podman failure, and [2] for
    usage or configuration errors. *)
