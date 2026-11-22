type entry = {
  project : string option;
  project_root : string option;
  container : string option;
  container_id : string;
  state : string;
  image : string option;
  image_id : string option;
}

let of_container (c : Podman.listed_container) =
  let label key = List.assoc_opt key c.labels in
  {
    project = label "dev.deco.project";
    project_root = label "dev.deco.project-root";
    container = (match c.names with name :: _ -> Some name | [] -> None);
    container_id = c.id;
    state = c.state;
    image = c.image;
    image_id = c.image_id;
  }

let compare_missing_last a b =
  match (a, b) with
  | Some a, Some b -> String.compare a b
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let sort entries =
  List.stable_sort
    (fun a b ->
      match compare_missing_last a.project b.project with
      | 0 -> (
          match compare_missing_last a.container b.container with
          | 0 -> String.compare a.container_id b.container_id
          | n -> n)
      | n -> n)
    entries

let empty_message = "No Deco-managed containers.\n"

let render_human = function
  | [] -> empty_message
  | entries ->
      (* Empty values are shown as missing so every cell has visible text. *)
      let cell = function
        | None | Some "" -> "-"
        | Some value -> Terminal_text.escape value
      in
      Text_table.render
        ~header:[ "PROJECT"; "CONTAINER"; "STATE"; "IMAGE"; "PROJECT ROOT" ]
        (List.map
           (fun e ->
             [
               cell e.project;
               cell e.container;
               cell (Some e.state);
               cell e.image;
               cell e.project_root;
             ])
           entries)

let render_json entries =
  let optional = function None -> `Null | Some value -> `String value in
  let entry e =
    `Assoc
      [
        ("project", optional e.project);
        ("project_root", optional e.project_root);
        ("container", optional e.container);
        ("container_id", `String e.container_id);
        ("state", `String e.state);
        ("image", optional e.image);
        ("image_id", optional e.image_id);
      ]
  in
  Yojson.Basic.pretty_to_string (`List (List.map entry entries)) ^ "\n"

let run ?run () =
  match Podman.available ?run () with
  | Error _ as error -> error
  | Ok () ->
      Result.map
        (fun containers -> sort (List.map of_container containers))
        (Podman.list_managed_containers ?run ())
