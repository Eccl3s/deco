(** Rendering for [deco actions] ([specs/deco-cli.md] §[deco actions]). Pure;
    the actions come from {!Config.Effective.t.actions}, already sorted by name.
*)

val render_human : (string * string) list -> string
(** A {!Text_table} with [NAME] and [COMMAND] columns, one row per action.
    Commands are escaped with {!Terminal_text.escape}, so a multi-line command
    stays on one row; validated names are already safe to print. With no
    actions, a one-line message. The output has no styling and ends with a
    newline. *)

val render_json : (string * string) list -> string
(** A JSON array of [{"name": ..., "command": ...}] objects in the given order,
    [[]] when empty, followed by one newline. *)
