(** Initialization writes only the two target files and necessary directories.
    Publication is atomic per file, not across the pair. Ordinary failures roll
    back; abrupt termination and concurrent external edits are not
    transactional. *)
type error = Invalid of string | Conflict of string | Filesystem of string

type file = {
  path : string;
  contents : string;
  original : (int * int * float * int) option;
}

type plan = private {
  root : string;
  template : Template.t;
  create_deco : bool;
  files : file list;
}

val prepare :
  path:string -> template:string -> replace:bool -> (plan, error) result
(** Read-only preflight; reject symlinked .deco/build components and output
    files. *)

val apply : plan -> (unit, error) result
(** Recheck destinations, stage both files, publish, and restore originals on
    failure. Recovery backups are retained and reported when rollback fails. *)

val error_to_string : error -> string
