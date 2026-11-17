type t = { root : string; config_path : string }
(** Filesystem project discovery without config parsing or working-directory
    changes. Input paths are relative to the process working directory. Search
    follows physical parents after canonicalizing the starting directory. Config
    symlinks do not change the canonical project root. Readability is checked by
    loading. *)

type error =
  | Not_found of { start_dir : string }
  | Missing_config of { root : string }
  | Not_directory of { path : string }
  | Not_regular_file of { path : string }
  | Filesystem_error of {
      operation : string;
      path : string;
      reason : Unix.error;
    }

val discover : start_dir:string -> (t, error) result
(** Find the nearest regular [.deco/config.toml]. Missing candidates are
    skipped; malformed candidates and other filesystem errors stop the search.
*)

val select : directory:string -> (t, error) result
(** Check only the selected directory, with no parent fallback. *)

val error_to_string : error -> string
