type mutation =
  | Stop_container
  | Remove_container
  | Build_image
  | Create_container
  | Start_container

type outcome = {
  stopped : bool;
  container_removed : bool;
  image_rebuilt : bool;
  image_id : string;
  container_id : string;
}

type cause =
  | Planning of string
  | Podman of Podman.error
  | Conflict of string
  | Runtime of string
  | Container_appeared
  | Hook of Hook.failure

type error = { cause : cause; completed : mutation list }

type progress =
  | Image_rebuilt
  | Image_kept
  | Container_removed of { stopped : bool }
  | No_container
  | Container_started

let run ?execute ?read_many ?probe ?hook ?warn
    ?(progress = fun (_ : progress) -> ()) (loaded : Config_loader.t)
    ~keep_image =
  let injected = execute in
  let execute =
    Option.value ~default:(fun output argv -> Process.run ~output argv) execute
  in
  let capture argv = execute Process.Capture argv in
  let completed = ref [] in
  let record mutation = completed := mutation :: !completed in
  let fail cause = Error { cause; completed = List.rev !completed } in
  let ( let* ) r f = match r with Ok x -> f x | Error e -> Error e in
  let owned = function
    | Ok x -> Ok x
    | Error (Container_runtime.Podman e) -> fail (Podman e)
    | Error (Container_runtime.Conflict e) -> fail (Conflict e)
  in
  let* plan =
    match Refresh_plan.make loaded ~keep_image with
    | Ok plan -> Ok plan
    | Error e -> fail (Planning e)
  in
  (* Every refusal is decided here, before any resource changes. *)
  let* initial =
    match
      Container_runtime.preflight
        ?run:(Option.map (fun _ -> capture) injected)
        ?read_many
        [
          Podman_command.version;
          Podman_command.inspect "container" plan.container_name;
          Podman_command.inspect "image" plan.image_reference;
        ]
    with
    | Ok reader -> Ok reader
    | Error e -> fail (Podman e)
  in
  let* () =
    match Podman.available ~run:initial () with
    | Ok () -> Ok ()
    | Error e -> fail (Podman e)
  in
  let* container =
    owned (Container_runtime.inspect_owned_container ~run:initial loaded)
  in
  let* image =
    owned (Container_runtime.inspect_owned_image ~run:initial loaded)
  in
  let* () =
    match image with
    | Podman.Absent when keep_image ->
        fail
          (Conflict
             "Configured image is missing; run deco refresh without \
              --keep-image")
    | Absent | Present _ -> Ok ()
  in
  (* Build first: the old container keeps running, and a failed build leaves
     it unchanged. [image] becomes the image the replacement will use. *)
  let* image =
    match plan.build with
    | None -> Ok image
    | Some build -> (
        let* () =
          match execute Process.Inherit build with
          | Error e -> fail (Runtime (e.operation ^ ": " ^ e.message))
          | Ok r when r.status = Unix.WEXITED 0 ->
              record Build_image;
              Ok ()
          | Ok r -> fail (Runtime ("Image build failed: " ^ Podman.message r))
        in
        let* rebuilt =
          owned (Container_runtime.inspect_owned_image ~run:capture loaded)
        in
        match rebuilt with
        | Podman.Present _ -> Ok rebuilt
        | Absent -> fail (Runtime "Image is missing after build"))
  in
  (* Assemble refuses this too, but only after the old container is gone. *)
  let* () =
    match image with
    | Podman.Absent -> Ok ()
    | Present image -> (
        match Container_runtime.unapplied_capabilities loaded image with
        | None -> Ok ()
        | Some message -> fail (Conflict message))
  in
  progress (if Option.is_some plan.build then Image_rebuilt else Image_kept);
  let* stopped, container_removed =
    match container with
    | Podman.Absent -> Ok (false, false)
    | Present _ -> (
        match Remove.run ~run:capture ?hook ?warn loaded ~keep_image:true with
        | Ok outcome ->
            if outcome.stopped then record Stop_container;
            if outcome.container_removed then record Remove_container;
            Ok (outcome.stopped, outcome.container_removed)
        | Error error ->
            List.iter
              (function
                | Remove.Stop_container -> record Stop_container
                | Remove_container -> record Remove_container
                | Remove_image -> ())
              error.completed;
            fail
              (match error.cause with
              | Remove.Planning e -> Planning e
              | Podman e -> Podman e
              | Conflict e -> Conflict e
              | Runtime e -> Runtime e
              | Image_in_use _ -> Conflict "Image is in use"
              | Hook failure -> Hook failure))
  in
  progress
    (if container_removed then Container_removed { stopped } else No_container);
  (* The replacement is recorded and reported as soon as it is running, so a
     failed hook after it is reported against a started container. A container
     that appeared after the removal was reused by assemble rather than
     created; it is refused before any hook runs. *)
  let ready = ref false and appeared = ref false in
  let on_ready (outcome : Assemble.outcome) =
    ready := true;
    if not outcome.created then (
      appeared := true;
      if outcome.started then record Start_container;
      Error (Assemble.Conflict "Container appeared"))
    else (
      record Create_container;
      if outcome.started then record Start_container;
      progress Container_started;
      Ok ())
  in
  match
    Assemble.run ?execute:injected ?read_many ?probe ?hook ~on_ready loaded
  with
  | Ok outcome ->
      Ok
        {
          stopped;
          container_removed;
          image_rebuilt = Option.is_some plan.build;
          image_id = outcome.image_id;
          container_id = outcome.container_id;
        }
  | Error _ when !appeared -> fail Container_appeared
  | Error error ->
      if not !ready then
        List.iter
          (fun command ->
            match String.split_on_char ' ' command with
            | [ "podman"; "--remote=false"; "build" ] -> record Build_image
            | [ "podman"; "--remote=false"; "create" ] ->
                record Create_container
            | [ "podman"; "--remote=false"; "start" ] -> record Start_container
            | _ -> ())
          error.completed;
      fail
        (match error.cause with
        | Assemble.Planning e -> Planning e
        | Podman e -> Podman e
        | Conflict e -> Conflict e
        | Runtime e -> Runtime e
        | Hook failure -> Hook failure)
