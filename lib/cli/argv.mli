(** Command-line pre-processing applied before Cmdliner parses [Sys.argv].

    Cmdliner cannot express three parts of the Deco CLI contract
    ([specs/deco-cli.md] §3): the [-h]/[-V] short aliases for [--help] and
    [--version], global options placed before the subcommand, and the mandatory
    [--] separator of [deco exec]. This module rewrites the argument vector so
    that Cmdliner can parse the rest. *)

type scope =
  | Global  (** Accepted before or after any subcommand. *)
  | Command of string  (** Accepted only after the named subcommand. *)

type option_spec = {
  names : string list;
      (** Cmdliner-style names: one letter for [-x], longer for [--name]. *)
  takes_value : bool;
  scope : scope;
}
(** An option whose value must not be mistaken for a command name or rewritten
    as an alias. Cmdliner [Arg.info] definitions reuse [names] so the two cannot
    drift apart. *)

val project_dir : option_spec
(** [--project-dir PATH], accepted by every project command. *)

val template : option_spec
(** [-t, --template NAME] for [deco init]. *)

val options : option_spec list
(** Every value-taking option. *)

type t = {
  argv : string array;
      (** Arguments for Cmdliner, with the executable name at index 0. For
          [exec], everything from the [--] separator onward is removed. *)
  exec_command : string list option;
      (** For [exec], the arguments after the first [--]; [None] when the
          separator is absent or the command is not [exec]. *)
}

val preprocess : string array -> t
(** [preprocess argv] rewrites a full argument vector, including the executable
    name. *)
