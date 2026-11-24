open Deco

(* A stateful fake Podman: mutations change what later inspections return. *)

(** Whose ownership labels a resource carries. [Moved] differs only in the
    project root, as after moving the project or for another project with the
    same name elsewhere. *)
type owner = Owned | Foreign | Moved | Unlabelled

type image = { id : string; owned : owner }

type container = {
  cid : string;
  mutable state : string;
  image_id : string;
  owner : owner;
}

type world = {
  mutable image : image option;
  mutable container : container option;
  mutable mutations : string list;  (** Mutating verbs, most recent first. *)
  mutable build_output : Process.output option;
  mutable next : int;
  mutable events : Refresh.progress list;  (** Most recent first. *)
  fail_build : bool;
  fail_start : bool;
  unavailable : bool;
  intruder : string option;
      (** When set, [container rm] is immediately followed by another owned
          container taking the name, in this state, as if created by a
          concurrent [deco assemble]. *)
}

let world ?image ?container ?(fail_build = false) ?(fail_start = false)
    ?(unavailable = false) ?intruder () =
  {
    image;
    container;
    mutations = [];
    build_output = None;
    next = 1;
    events = [];
    fail_build;
    fail_start;
    unavailable;
    intruder;
  }

let image_name = "example-dev-image:latest"
let container_name = "example-dev-container"

let labels = function
  | Unlabelled -> "{}"
  | owner ->
      Printf.sprintf
        {|{"dev.deco.managed":"true","dev.deco.project":"%s","dev.deco.project-root":"%s"}|}
        (if owner = Foreign then "other" else "example")
        (if owner = Moved then "/old/project" else "/project")

let ok stdout = Ok { Process.status = Unix.WEXITED 0; stdout; stderr = "" }
let exit n = Ok { Process.status = Unix.WEXITED n; stdout = ""; stderr = "" }

let execute w output argv =
  if w.unavailable then
    Error { Process.operation = "launch"; message = "No such file" }
  else
    let image_matches name =
      match w.image with
      | Some i when name = image_name || name = i.id -> Some i
      | _ -> None
    in
    let container_matches name =
      match w.container with
      | Some c when name = container_name || name = c.cid -> Some c
      | _ -> None
    in
    let mutate verb =
      w.mutations <- verb :: w.mutations;
      ok ""
    in
    match argv with
    | [ "podman"; "--remote=false"; "version" ] -> ok ""
    | [ "podman"; "--remote=false"; "info"; "--format"; "json" ] -> ok "{}"
    | [ "podman"; "--remote=false"; "image"; "inspect"; "--"; name ] -> (
        match image_matches name with
        | None -> exit 125
        | Some i ->
            ok
              (Printf.sprintf
                 {|[{"Id":"%s","Labels":%s,"Config":{"User":"","WorkingDir":"/"}}]|}
                 i.id (labels i.owned)))
    | [ "podman"; "--remote=false"; "image"; "exists"; "--"; name ] ->
        exit (if image_matches name = None then 1 else 0)
    | [ "podman"; "--remote=false"; "container"; "inspect"; "--"; name ] -> (
        match container_matches name with
        | None -> exit 125
        | Some c ->
            ok
              (Printf.sprintf
                 {|[{"Id":"%s","Image":"%s","Config":{"Labels":%s,"User":"","WorkingDir":"/"},"HostConfig":{"Init":true,"UsernsMode":""},"State":{"Status":"%s"},"Mounts":[]}]|}
                 c.cid c.image_id (labels c.owner) c.state))
    | [ "podman"; "--remote=false"; "container"; "exists"; "--"; name ] ->
        exit (if container_matches name = None then 1 else 0)
    | [ "podman"; "--remote=false"; "stop"; "--"; id ] ->
        (Option.get (container_matches id)).state <- "exited";
        mutate "stop"
    | [ "podman"; "--remote=false"; "container"; "rm"; "--"; id ] ->
        assert (container_matches id <> None);
        w.container <-
          Option.map
            (fun state ->
              {
                cid = "intruder";
                state;
                image_id = (Option.get w.image).id;
                owner = Owned;
              })
            w.intruder;
        mutate "rm"
    | "podman" :: "--remote=false" :: "build" :: _ ->
        w.build_output <- Some output;
        if w.fail_build then exit 1
        else (
          w.image <-
            Some { id = Printf.sprintf "built%d" w.next; owned = Owned };
          w.next <- w.next + 1;
          mutate "build")
    | "podman" :: "--remote=false" :: "create" :: rest ->
        let image_id = List.nth rest (List.length rest - 1) in
        let cid = Printf.sprintf "%064x" w.next in
        w.next <- w.next + 1;
        w.container <- Some { cid; state = "created"; image_id; owner = Owned };
        ignore (mutate "create");
        ok (cid ^ "\n")
    | [ "podman"; "--remote=false"; "start"; "--"; id ] ->
        if w.fail_start then exit 125
        else (
          (Option.get (container_matches id)).state <- "running";
          mutate "start")
    | _ -> failwith ("Unexpected command: " ^ String.concat " " argv)

let () =
  let source =
    Result.get_ok (Config.Decode.from_string "[project]\nname='example'\n")
  in
  let effective = Result.get_ok (Config.Resolve.apply source) in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      source;
      effective;
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
        };
      identity = User_identity.Image;
    }
  in
  let old_image = { id = "old"; owned = Owned } in
  let running () =
    { cid = "oldc"; state = "running"; image_id = "old"; owner = Owned }
  in
  let refresh ?(keep_image = false) w =
    Refresh.run ~execute:(execute w)
      ~probe:(fun () -> Some false)
      ~progress:(fun event -> w.events <- event :: w.events)
      loaded ~keep_image
  in
  let mutations w = List.rev w.mutations in
  let events w = List.rev w.events in
  let removed stopped = Refresh.Container_removed { stopped } in

  (* Running container: rebuild first, then stop, remove, create, start. *)
  let w = world ~image:old_image ~container:(running ()) () in
  (match refresh w with
  | Ok o ->
      assert (o.stopped && o.container_removed && o.image_rebuilt);
      assert (o.image_id = "built1");
      assert (o.container_id <> "oldc");
      assert ((Option.get w.container).state = "running");
      assert ((Option.get w.container).image_id = "built1")
  | Error _ -> failwith "running refresh failed");
  assert (mutations w = [ "build"; "stop"; "rm"; "create"; "start" ]);
  assert (events w = [ Image_rebuilt; removed true; Container_started ]);
  assert (w.build_output = Some Process.Inherit);

  (* Stopped container: no stop. *)
  let w =
    world ~image:old_image ~container:{ (running ()) with state = "exited" } ()
  in
  (match refresh w with
  | Ok o -> assert ((not o.stopped) && o.container_removed && o.image_rebuilt)
  | Error _ -> failwith "stopped refresh failed");
  assert (mutations w = [ "build"; "rm"; "create"; "start" ]);
  assert (events w = [ Image_rebuilt; removed false; Container_started ]);

  (* No container: skip the stop and removal. *)
  let w = world ~image:old_image () in
  (match refresh w with
  | Ok o ->
      assert ((not o.stopped) && (not o.container_removed) && o.image_rebuilt)
  | Error _ -> failwith "missing-container refresh failed");
  assert (mutations w = [ "build"; "create"; "start" ]);
  assert (events w = [ Image_rebuilt; No_container; Container_started ]);

  (* No image and no container: build from scratch. *)
  let w = world () in
  assert (Result.is_ok (refresh w));
  assert (mutations w = [ "build"; "create"; "start" ]);
  assert (events w = [ Image_rebuilt; No_container; Container_started ]);

  (* --keep-image: recreate the container from the existing image. *)
  let w = world ~image:old_image ~container:(running ()) () in
  (match refresh ~keep_image:true w with
  | Ok o ->
      assert (o.stopped && o.container_removed && not o.image_rebuilt);
      assert (o.image_id = "old");
      assert ((Option.get w.container).image_id = "old")
  | Error _ -> failwith "keep-image refresh failed");
  assert (mutations w = [ "stop"; "rm"; "create"; "start" ]);
  assert (events w = [ Image_kept; removed true; Container_started ]);
  assert (w.build_output = None);

  (* Refusals happen before any mutation and leave resources untouched. *)
  let refused ?keep_image ?(prefix = "") w =
    (match refresh ?keep_image w with
    | Error { cause = Conflict message; completed = [] }
      when String.starts_with ~prefix message ->
        ()
    | _ -> failwith "expected a conflict before any mutation");
    assert (mutations w = [] && events w = [])
  in
  let w = world ~container:(running ()) () in
  refused ~keep_image:true w;
  assert ((Option.get w.container).state = "running");
  List.iter
    (fun owner ->
      let container = "container example-dev-container "
      and image = "image example-dev-image:latest " in
      refused ~prefix:container
        (world ~image:old_image ~container:{ (running ()) with owner } ());
      refused ~prefix:image
        (world
           ~image:{ old_image with owned = owner }
           ~container:(running ()) ());
      refused ~prefix:image (world ~image:{ old_image with owned = owner } ()))
    [ Foreign; Moved; Unlabelled ];

  (* A failed build happens before the old container is touched. *)
  let w = world ~image:old_image ~container:(running ()) ~fail_build:true () in
  (match refresh w with
  | Error { cause = Runtime _; completed = [] } -> ()
  | _ -> failwith "expected a build failure with nothing completed");
  assert (mutations w = []);
  assert (events w = []);
  assert (
    match w.container with
    | Some { cid = "oldc"; state = "running"; image_id = "old"; _ } -> true
    | _ -> false);

  (* A start failure reports every completed step. *)
  let w = world ~image:old_image ~container:(running ()) ~fail_start:true () in
  (match refresh w with
  | Error
      {
        cause = Runtime _;
        completed =
          [ Build_image; Stop_container; Remove_container; Create_container ];
      } ->
      ()
  | _ -> failwith "expected a partial start failure");
  assert (events w = [ Image_rebuilt; removed true ]);

  (* A container that takes the name after removal is not adopted. *)
  let w =
    world ~image:old_image ~container:(running ()) ~intruder:"running" ()
  in
  (match refresh w with
  | Error
      {
        cause = Container_appeared;
        completed = [ Build_image; Stop_container; Remove_container ];
      } ->
      ()
  | _ -> failwith "expected a running intruder to be refused");
  assert (mutations w = [ "build"; "stop"; "rm" ]);
  assert (events w = [ Image_rebuilt; removed true ]);
  assert ((Option.get w.container).cid = "intruder");
  (* A stopped intruder is started by assemble before refresh can refuse it;
     the start is reported, and the error still says it was not replaced. *)
  let w =
    world ~image:old_image ~container:(running ()) ~intruder:"exited" ()
  in
  (match refresh w with
  | Error
      {
        cause = Container_appeared;
        completed =
          [ Build_image; Stop_container; Remove_container; Start_container ];
      } ->
      ()
  | _ -> failwith "expected a stopped intruder to be refused");
  assert (mutations w = [ "build"; "stop"; "rm"; "start" ]);
  assert (events w = [ Image_rebuilt; removed true ]);

  (* Unavailable Podman. *)
  (match refresh (world ~unavailable:true ()) with
  | Error { cause = Podman (Podman.Unavailable _); completed = [] } -> ()
  | _ -> failwith "expected unavailable Podman");

  (* Invalid plans fail before Podman is used. *)
  let bad =
    {
      loaded with
      effective =
        {
          loaded.effective with
          container = { loaded.effective.container with name = "bad\000name" };
        };
    }
  in
  match
    Refresh.run
      ~execute:(fun _ _ -> failwith "Podman must not be called")
      bad ~keep_image:false
  with
  | Error { cause = Planning _; completed = [] } -> ()
  | _ -> failwith "expected a planning error"

(* Hooks: pre_stop before the old container stops, then post_create and
   post_start in the replacement after it is reported as started. A failed
   pre_stop changes no container; a failed post hook is a partial refresh with
   the replacement running. No hook runs in a container that appeared. *)
let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "project.name='example'\n\
          hooks={pre_stop='a',post_create='b',post_start='c'}\n")
  in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
        };
      identity = User_identity.Image;
    }
  in
  let running () =
    { cid = "oldc"; state = "running"; image_id = "old"; owner = Owned }
  in
  let refresh ?(fail = "") w =
    let hook argv =
      let name, container =
        match List.rev argv with
        | "a" :: "-c" :: "sh" :: c :: _ -> ("pre_stop", c)
        | "b" :: "-c" :: "sh" :: c :: _ -> ("post_create", c)
        | "c" :: "-c" :: "sh" :: c :: _ -> ("post_start", c)
        | _ -> failwith ("Unexpected hook: " ^ String.concat " " argv)
      in
      (* Hooks run in the container that is running at that moment. *)
      let current = Option.get w.container in
      assert (current.cid = container && current.state = "running");
      w.mutations <- name :: w.mutations;
      Ok
        {
          Process.status = Unix.WEXITED (if name = fail then 8 else 0);
          stdout = "";
          stderr = "";
        }
    in
    Refresh.run ~execute:(execute w) ~hook
      ~probe:(fun () -> Some false)
      ~progress:(fun event ->
        w.mutations <-
          (match event with
          | Refresh.Container_started -> "progress:started"
          | _ -> "progress")
          :: w.mutations)
      loaded ~keep_image:false
  in
  let mutations w =
    List.filter (fun m -> m <> "progress") (List.rev w.mutations)
  in
  let w =
    world ~image:{ id = "old"; owned = Owned } ~container:(running ()) ()
  in
  assert (Result.is_ok (refresh w));
  assert (
    mutations w
    = [
        "build";
        "pre_stop";
        "stop";
        "rm";
        "create";
        "start";
        "progress:started";
        "post_create";
        "post_start";
      ]);
  (* A failed pre_stop leaves the old container running; only the build
     completed. *)
  let w =
    world ~image:{ id = "old"; owned = Owned } ~container:(running ()) ()
  in
  (match refresh ~fail:"pre_stop" w with
  | Error
      {
        cause = Hook (Hook.Exited { hook = Pre_stop; status = WEXITED 8 });
        completed = [ Build_image ];
      } ->
      ()
  | _ -> assert false);
  assert (mutations w = [ "build"; "pre_stop" ]);
  assert ((Option.get w.container).cid = "oldc");
  assert ((Option.get w.container).state = "running");
  (* A failed post_create after the removal: the replacement is running and
     post_start does not run. *)
  List.iter
    (fun (fail, ran) ->
      let w =
        world ~image:{ id = "old"; owned = Owned } ~container:(running ()) ()
      in
      (match refresh ~fail w with
      | Error
          {
            cause = Hook failure;
            completed =
              [
                Build_image;
                Stop_container;
                Remove_container;
                Create_container;
                Start_container;
              ];
          } ->
          assert (Hook.to_string (Hook.failed failure) = fail)
      | _ -> assert false);
      assert (
        mutations w
        = [
            "build";
            "pre_stop";
            "stop";
            "rm";
            "create";
            "start";
            "progress:started";
          ]
          @ ran);
      assert ((Option.get w.container).state = "running");
      assert ((Option.get w.container).cid <> "oldc"))
    [
      ("post_create", [ "post_create" ]);
      ("post_start", [ "post_create"; "post_start" ]);
    ];
  (* A container that appears after the removal is refused before any hook
     runs in it. *)
  let w =
    world
      ~image:{ id = "old"; owned = Owned }
      ~container:(running ()) ~intruder:"exited" ()
  in
  (match refresh w with
  | Error { cause = Container_appeared; _ } -> ()
  | _ -> assert false);
  assert (mutations w = [ "build"; "pre_stop"; "stop"; "rm"; "start" ])

(* Refresh checks the image's capabilities label after building and before
   removing the old container, so a refused cap_add leaves it running. *)
let () =
  let source =
    Result.get_ok
      (Config.Decode.from_string
         "[project]\nname='example'\n[container]\ncap_add=['SYS_ADMIN']\n")
  in
  let loaded : Config_loader.t =
    {
      ignored_paths = [];
      contents = "";
      source;
      effective = Result.get_ok (Config.Resolve.apply source);
      project =
        { root = "/project"; config_path = "/project/.deco/config.toml" };
      host_paths =
        {
          build_context = "/project/.deco/build";
          containerfile = "/project/.deco/build/Containerfile";
          workspace_source = None;
        };
      identity = User_identity.Image;
    }
  in
  (* The fake's images carry the label in addition to their ownership labels. *)
  let labelled w output argv =
    match (execute w output argv, argv) with
    | Ok r, [ "podman"; "--remote=false"; "image"; "inspect"; "--"; _ ]
      when r.Process.status = Unix.WEXITED 0 ->
        let marker = {|"Labels":{|} in
        let i =
          let rec find i =
            if String.sub r.stdout i (String.length marker) = marker then i
            else find (i + 1)
          in
          find 0 + String.length marker
        in
        Ok
          {
            r with
            stdout =
              String.sub r.stdout 0 i
              ^ {|"io.containers.capabilities":"CHOWN",|}
              ^ String.sub r.stdout i (String.length r.stdout - i);
          }
    | result, _ -> result
  in
  List.iter
    (fun keep_image ->
      let w =
        world
          ~image:{ id = "old"; owned = Owned }
          ~container:
            { cid = "oldc"; state = "running"; image_id = "old"; owner = Owned }
          ()
      in
      (match
         Refresh.run ~execute:(labelled w)
           ~probe:(fun () -> Some false)
           loaded ~keep_image
       with
      | Error { cause = Conflict message; _ } ->
          assert (
            String.starts_with ~prefix:"Image example-dev-image:latest" message)
      | _ -> failwith "expected the capabilities conflict");
      (* Nothing but the build ran; the old container is still running. *)
      assert (List.rev w.mutations = if keep_image then [] else [ "build" ]);
      assert ((Option.get w.container).cid = "oldc");
      assert ((Option.get w.container).state = "running"))
    [ false; true ]
