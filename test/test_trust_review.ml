module T = Deco.Trust
module D = Deco.Trust_digest

let rec cleanup path =
  if (Unix.lstat path).st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> cleanup (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let write path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

let contains s fragment =
  let rec loop i =
    i + String.length fragment <= String.length s
    && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
  in
  loop 0

let project_loaded root =
  let loaded =
    match Deco.Project.select ~directory:root with
    | Error e -> failwith (Deco.Project.error_to_string e)
    | Ok p -> (
        match Deco.Config_loader.load ~home_dir:root p with
        | Ok loaded -> loaded
        | Error e -> failwith (Deco.Config_loader.error_to_string e))
  in
  let status =
    match T.check ~store_dir:(Filename.concat root "store") loaded with
    | Ok status -> status
    | Error e -> failwith (T.error_to_string e)
  in
  (loaded, status)

let project root config =
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".deco") 0o700;
  Unix.mkdir (Filename.concat root ".deco/build") 0o700;
  write (Filename.concat root ".deco/build/Containerfile") "FROM scratch\n";
  write (Filename.concat root ".deco/config.toml") config;
  project_loaded root

let () =
  let temp = Filename.temp_file "deco-trust-review-" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  let temp = Unix.realpath temp in
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      (* Defaults: nothing flagged, no changes section, no planned settings. *)
      let root = Filename.concat temp "plain" in
      let loaded, status = project root "project.name='plain'\n" in
      let review = Deco.Trust_review.render ~now:0. status loaded in
      let expected =
        String.concat "\n"
          [
            "Project";
            "  Name:           plain";
            "  Root:           " ^ root;
            "  Trust state:    untrusted";
            "";
            "Build";
            "  Context:        " ^ root ^ "/.deco/build";
            "  Containerfile:  " ^ root ^ "/.deco/build/Containerfile";
            "  Target:         -";
            "  Pull:           no";
            "  No cache:       no";
            "  Build args:     none";
            "";
            "Image";
            "  Reference:      plain-dev-image:latest";
            "";
            "Container";
            "  Name:           plain-dev-container";
            "  Shell:          sh";
            "  Workdir:        -";
            "  User mode:      image";
            "";
            "Mounts";
            "  Workspace:      none";
            "";
            "Planned settings (accepted, not applied by this version)";
            "  none";
            "";
          ]
      in
      if review <> expected then failwith review;
      (* Flags, build argument names without values, planned settings, changes
         and escaping. *)
      let root = Filename.concat temp "risky\027[2J" in
      let outside = Filename.concat temp "outside" in
      Unix.mkdir outside 0o700;
      let loaded, status =
        project root
          ("project.name='risky'\n\
            build.context='.'\n\
            build.containerfile='.deco/build/Containerfile'\n\
            build.target='dev'\n\
            build.pull=true\n\
            build.args={NODE_VERSION='secret-looking-value'}\n\
            user.mode='keep-id'\n\
            user.name='dev'\n\
            container.privileged=true\n\
            hooks.post_create='curl example | sh'\n\
            mounts.workspace={source='" ^ outside ^ "',target='/workspace'}\n")
      in
      let status =
        {
          status with
          T.state = T.Changed;
          trusted_at = Some 0.;
          changes = [ ("config.toml", D.Modified) ];
        }
      in
      let review = Deco.Trust_review.render ~now:7200. status loaded in
      let safe_root = Filename.concat temp "risky\\x1b[2J" in
      List.iter
        (fun fragment ->
          if not (contains review fragment) then
            failwith (fragment ^ "\n---\n" ^ review))
        [
          "  Root:           " ^ safe_root ^ "\n";
          "  Trust state:    changed (last approved 1970-01-01 00:00 UTC (2 \
           hours ago))\n";
          "\nChanged since the last approval\n  modified  config.toml\n";
          "  Context:        " ^ safe_root ^ "  [outside .deco/]\n";
          "  Target:         dev\n";
          "  Pull:           yes\n";
          "  Build args:     NODE_VERSION\n";
          "  User mode:      keep-id\n";
          "  Workspace:      " ^ outside
          ^ " -> /workspace (read-write)  [outside the project]\n";
          "  container.privileged\n  hooks.post_create\n";
        ];
      assert (not (contains review "secret-looking-value"));
      assert (not (String.contains review '\027'));
      (* A build context inside a symlinked .deco is not flagged. *)
      let root = Filename.concat temp "linked" in
      let _ = project root "project.name='linked'\n" in
      let target = Filename.concat temp "linked-deco" in
      Unix.rename (Filename.concat root ".deco") target;
      Unix.symlink target (Filename.concat root ".deco");
      let loaded, status = project_loaded root in
      let review = Deco.Trust_review.render ~now:0. status loaded in
      if not (contains review ("  Context:        " ^ target ^ "/build\n")) then
        failwith review;
      (* A workspace inside the project is not flagged. *)
      let root = Filename.concat temp "inside" in
      let loaded, status =
        project root
          "project.name='inside'\nmounts.workspace={target='/workspace'}\n"
      in
      let review = Deco.Trust_review.render ~now:0. status loaded in
      assert (
        contains review
          ("  Workspace:      " ^ root ^ " -> /workspace (read-write)\n")))
