val project_dir : string option Cmdliner.Term.t
val exits : Cmdliner.Cmd.Exit.info list
val load_project : string option -> (Deco.Config_loader.t, int) result
