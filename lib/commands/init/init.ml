type error = Invalid of string | Conflict of string | Filesystem of string

type file = {
  path : string;
  contents : string;
  original : (int * int * float * int) option;
}

type plan = {
  root : string;
  template : Template.t;
  create_deco : bool;
  files : file list;
}

exception Problem of error

let error_to_string = function Invalid s | Conflict s | Filesystem s -> s

let protect f =
  try Ok (f ()) with
  | Problem error -> Error error
  | Unix.Unix_error (e, op, path) ->
      Error (Filesystem (op ^ " " ^ path ^ ": " ^ Unix.error_message e))
  | Sys_error message -> Error (Filesystem message)

let stat path =
  try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let fingerprint stat =
  (stat.Unix.st_dev, stat.Unix.st_ino, stat.Unix.st_mtime, stat.Unix.st_size)

let rec absolute path =
  try Unix.realpath path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> (
    let parent = Filename.dirname path in
    if parent = path then raise (Problem (Invalid ("Cannot resolve " ^ path)));
    let parent = absolute parent in
    match Filename.basename path with
    | "." -> parent
    | ".." -> Filename.dirname parent
    | name -> Filename.concat parent name)

let directory path =
  match stat path with
  | None -> ()
  | Some s when s.Unix.st_kind = Unix.S_DIR -> ()
  | Some _ ->
      raise
        (Problem
           (Invalid ("Expected a directory, not a symlink or file: " ^ path)))

let prepare ~path ~template ~replace =
  protect (fun () ->
      let template =
        match Template.find template with
        | Some t -> t
        | None ->
            raise
              (Problem
                 (Invalid
                    ("Unknown template " ^ template
                   ^ "; use deco init --list-templates")))
      in
      let root = absolute path in
      directory root;
      let deco = Filename.concat root ".deco" in
      directory deco;
      directory (Filename.concat deco "build");
      let file path contents =
        let original =
          match stat path with
          | None -> None
          | Some s when s.Unix.st_kind <> Unix.S_REG ->
              raise (Problem (Conflict ("Not a regular target file: " ^ path)))
          | Some _ when not replace ->
              raise
                (Problem (Conflict ("Target exists; use --replace: " ^ path)))
          | Some s -> Some (fingerprint s)
        in
        { path; contents; original }
      in
      let config =
        Template.render template ~basename:(Filename.basename root)
      in
      {
        root;
        template;
        create_deco = stat deco = None;
        files =
          [
            file (Filename.concat deco "config.toml") config;
            file
              (Filename.concat deco "build/Containerfile")
              template.containerfile;
          ];
      })

let apply_internal ?(before_publish = fun _ -> ()) plan =
  protect (fun () ->
      let created = ref []
      and staged = ref []
      and backups = ref []
      and published = ref [] in
      let rec mkdir path =
        match stat path with
        | Some _ -> directory path
        | None ->
            mkdir (Filename.dirname path);
            Unix.mkdir path 0o755;
            created := path :: !created
      in
      let remove path =
        try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ()
      in
      let temporary path =
        Filename.temp_file ~temp_dir:(Filename.dirname path) ".deco-init-"
          ".tmp"
      in
      try
        directory (Filename.concat plan.root ".deco");
        directory (Filename.concat plan.root ".deco/build");
        List.iter
          (fun file ->
            directory (Filename.dirname file.path);
            let current = Option.map fingerprint (stat file.path) in
            if current <> file.original then
              raise (Problem (Conflict ("Target changed: " ^ file.path))))
          plan.files;
        List.map
          (fun file ->
            mkdir (Filename.dirname file.path);
            let temp = temporary file.path in
            staged := temp :: !staged;
            Out_channel.with_open_bin temp (fun channel ->
                output_string channel file.contents);
            Unix.chmod temp 0o644;
            let backup =
              Option.map
                (fun _ ->
                  let backup = temporary file.path in
                  remove backup;
                  Unix.link file.path backup;
                  backups := backup :: !backups;
                  backup)
                file.original
            in
            (file, temp, backup))
          plan.files
        |> List.iteri (fun index (file, temp, backup) ->
            before_publish index;
            directory (Filename.concat plan.root ".deco");
            directory (Filename.concat plan.root ".deco/build");
            if Option.map fingerprint (stat file.path) <> file.original then
              raise (Problem (Conflict ("Target changed: " ^ file.path)));
            (match file.original with
            | None -> Unix.link temp file.path
            | Some _ -> Unix.rename temp file.path);
            published := (file.path, backup) :: !published);
        (* Publication is complete: cleanup must never initiate rollback after
           some backups have already been removed. *)
        List.iter
          (fun path -> try remove path with Unix.Unix_error _ -> ())
          !backups;
        List.iter
          (fun path -> try remove path with Unix.Unix_error _ -> ())
          !staged
      with exn ->
        let failed = ref [] in
        List.iter
          (fun (path, backup) ->
            try
              match backup with
              | Some backup -> Unix.rename backup path
              | None -> remove path
            with _ -> failed := path :: !failed)
          !published;
        List.iter (fun path -> try remove path with _ -> ()) !staged;
        if !failed = [] then
          List.iter (fun path -> try remove path with _ -> ()) !backups;
        List.iter (fun path -> try Unix.rmdir path with _ -> ()) !created;
        if !failed <> [] then
          raise
            (Problem
               (Filesystem
                  ("Rollback failed for " ^ String.concat ", " !failed
                 ^ "; recovery backups: "
                  ^ String.concat ", " !backups)));
        raise exn)

let apply plan = apply_internal plan
