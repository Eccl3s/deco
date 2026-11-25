(** The create-settings digest: a hash of the create-time settings a container
    was created with, recorded in the {!label} label so that a later change to
    any of them makes the container incompatible. Settings that inspect data
    cannot report reliably (merged environments, defaulted capabilities, env
    file contents) are compared only through this digest. Only the digest is
    recorded, never the values, which may be secrets. *)

val label : string
(** ["dev.deco.create-digest"]. *)

val fields : Config_loader.t -> (string * string) list
(** The canonical create-time settings as [(key, value)] pairs with unique keys.
    A setting contributes a pair only when it adds something to [podman create];
    a setting that leaves the command as Deco 0.3.0 would have built it
    contributes nothing. A container created without {!label} is therefore
    equivalent to one whose settings are all at those values, and adding a
    setting does not change the digest of configurations that leave it unset.

    Contributing settings: [container.privileged] (["true"], only when enabled)
    and the non-empty [container.devices], [container.cap_add],
    [container.cap_drop] and [container.security_options] lists, each as its
    values in configured order, each value prefixed with its length as a 64-bit
    big-endian integer so distinct lists cannot share a value. *)

val digest : (string * string) list -> string
(** [blake2b-256:] followed by lowercase hexadecimal, over the pairs sorted by
    key, each key and value length-prefixed so distinct lists cannot collide.
    Order does not matter. Raises [Invalid_argument] on duplicate keys. *)

val of_loaded : Config_loader.t -> string
(** [digest (fields loaded)]. *)
