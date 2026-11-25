(** Pure planning for [deco run] ([specs/deco-cli.md] §[deco run]): the named
    action runs as [<container.shell> -c <command>] through the same preparation
    and [podman exec] as [deco exec]. No terminal detection, filesystem access
    or Podman calls. *)

type error =
  | Unknown_action of string  (** No action with this name is configured. *)
  | Planning of string  (** {!Exec_plan.make} rejected the command. *)

type t = private {
  name : string;
  command : string;  (** The configured action command. *)
  argv : string list;
      (** The command handed to {!Exec.run}: [[shell; "-c"; command]]. *)
  exec : Exec_plan.t;
}

val make : Config_loader.t -> tty:bool -> string -> (t, error) result
(** Look up the action by its exact, case-sensitive name, then plan it with
    {!Exec_plan.make}, which supplies the TTY flags, user, workdir and NUL-byte
    checks. *)

val render : t -> string
(** Describe the preparation shared with [deco exec], including a conditional
    start and the hooks that follow it, then the action. The action name and
    command are escaped with {!Terminal_text.escape} because previews do not
    require trust. *)
