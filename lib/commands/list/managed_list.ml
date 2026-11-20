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

(* Escape anything a terminal could interpret: C0 and C1 controls, DEL,
   bidirectional formatting characters, and bytes that are not valid UTF-8. *)
let escape text =
  let buffer = Buffer.create (String.length text) in
  let rec loop i =
    if i < String.length text then (
      let decoded = String.get_utf_8_uchar text i in
      let length = Uchar.utf_decode_length decoded in
      (if not (Uchar.utf_decode_is_valid decoded) then
         for j = i to i + length - 1 do
           Printf.bprintf buffer "\\x%02x" (Char.code text.[j])
         done
       else
         let code = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
         if
           code < 0x20
           || (code >= 0x7f && code <= 0x9f)
           || (code >= 0x200e && code <= 0x200f)
           || (code >= 0x202a && code <= 0x202e)
           || (code >= 0x2066 && code <= 0x2069)
         then
           if code <= 0xff then Printf.bprintf buffer "\\x%02x" code
           else Printf.bprintf buffer "\\u{%04x}" code
         else Buffer.add_string buffer (String.sub text i length));
      loop (i + length))
  in
  loop 0;
  Buffer.contents buffer

let empty_message = "No Deco-managed containers.\n"

let render_human = function
  | [] -> empty_message
  | entries ->
      (* Empty values are shown as missing so every cell has visible text. *)
      let cell = function
        | None | Some "" -> "-"
        | Some value -> escape value
      in
      let header =
        [ "PROJECT"; "CONTAINER"; "STATE"; "IMAGE"; "PROJECT ROOT" ]
      in
      let columns =
        [
          (fun e -> cell e.project);
          (fun e -> cell e.container);
          (fun e -> cell (Some e.state));
          (fun e -> cell e.image);
          (fun e -> cell e.project_root);
        ]
      in
      (* One multi-line cell per column keeps a single rule under the header;
         escaping guarantees each value is one line, so rows stay aligned. *)
      let body =
        List.map
          (fun value ->
            PrintBox.text (String.concat "\n" (List.map value entries)))
          columns
      in
      let table =
        PrintBox.frame
          (PrintBox.grid_l ~pad:(PrintBox.hpad 1) ~bars:true
             [ List.map PrintBox.line header; body ])
      in
      PrintBox_text.to_string_with ~style:false table ^ "\n"

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
