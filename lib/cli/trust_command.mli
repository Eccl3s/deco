val command : int Cmdliner.Cmd.t
(** [deco trust]: review and approve the project's configuration, or show or
    revoke its trust. Exits [0] on success, including when already trusted and
    for [--show], [--dry-run] and [--revoke]; [1] when the prompt is declined,
    [.deco/] changes during review, or the trust store cannot be written; [2]
    for usage or configuration errors, an uncomputable digest, and when
    confirmation is needed outside a terminal without [--yes]. *)
