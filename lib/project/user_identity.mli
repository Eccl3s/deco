type ids = { uid : int; gid : int }
(** Resolved identities, without account lookup, Podman checks or command
    generation. *)

type t = Image | Keep_id of { name : string; host : ids; container : ids }

val exec_user : t -> string option
(** The [--user] value for commands Deco runs in the container: the account name
    for keep-id, [None] (the container's user) for image mode. *)

val resolve :
  ?host_ids:(unit -> (ids, string) result) ->
  Config.Effective.user ->
  (t, Config.Diagnostic.t list) result
(** Call the provider once for keep-id, never for image mode. The default uses
    Unix.getuid/getgid. IDs must be in 0–4294967294 and representable by int.
    Host and container IDs need not match. Return sorted diagnostics for
    malformed effective records or provider failures. Account existence and
    namespace feasibility remain unchecked. *)
