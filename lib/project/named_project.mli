(** Project selection by configured name, for the global [--project] option.

    Podman ownership labels only locate the candidate project root: the
    configuration found there is loaded, validated and checked against the
    requested name before it is returned. Callers still verify resource
    ownership against the loaded configuration before any mutation. No functions
    print or assign CLI exit codes. *)

type error =
  | Podman of Podman.error  (** Podman availability or listing failed. *)
  | No_match of { name : string; invalid_roots : string list }
      (** No managed container records an absolute root for [name].
          [invalid_roots] holds any non-absolute root labels that were ignored,
          sorted and without duplicates. *)
  | Ambiguous of { name : string; roots : string list }
      (** More than one distinct root; [roots] is sorted. *)
  | Root of { name : string; root : string; error : Project.error }
      (** The single root is missing, not a directory, or lacks
          [.deco/config.toml]. *)
  | Config of Config_loader.error  (** The configuration at the root failed. *)
  | Name_mismatch of {
      name : string;
      root : string;
      config_path : string;
      configured : string;
    }  (** The configuration at the root names a different project. *)

type candidates = {
  roots : string list;
      (** Canonical absolute roots, sorted and without duplicates. *)
  invalid_roots : string list;
      (** Non-absolute (including empty) root labels, as recorded, sorted and
          without duplicates. *)
}

val candidates : name:string -> Podman.listed_container list -> candidates
(** Roots recorded by containers labelled [dev.deco.project=name]. Absolute
    [dev.deco.project-root] values are canonicalized, resolving symlinks; values
    that cannot be canonicalized, such as deleted roots, are kept as recorded.
    Non-absolute values are never resolved, because Deco only records absolute
    roots and resolving them would depend on the working directory. Containers
    without a root label are ignored. *)

val load :
  ?run:Podman.runner ->
  ?load:(Project.t -> (Config_loader.t, Config_loader.error) result) ->
  name:string ->
  unit ->
  (Config_loader.t, error) result
(** Check that Podman is available, list managed containers, and select the
    single root from {!candidates}. Then select the project there without parent
    fallback and require its [project.name] to equal [name], first with a
    lenient read ({!Config.Decode.project_name}) so that a different project is
    reported as a mismatch even when its configuration is invalid. Finally load
    it with [?load] (default {!Config_loader.load}) and check the name again.
    Only read-only Podman operations are performed. *)

val error_to_string : error -> string
(** A one-line description. [Config] errors use
    {!Config_loader.error_to_string}; callers may report them in more detail. *)
