type t = {
  name : string;
  description : string;
  config_template : string;
  containerfile : string;
}

let all =
  List.map
    (fun (name, containerfile, config_template) ->
      {
        name;
        containerfile;
        config_template;
        description =
          (match name with
          | "python" -> "Python uv development container"
          | "go" -> "Go development container"
          | "rust" -> "Rust development container"
          | _ -> String.capitalize_ascii name ^ " development container");
      })
    (List.sort compare Template_data.files)

let find name = List.find_opt (fun template -> template.name = name) all

let project_name basename =
  let buffer = Buffer.create 128 in
  let allowed = function
    | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  let replacing = ref false in
  String.iter
    (fun c ->
      let c = Char.lowercase_ascii c in
      if allowed c then (
        Buffer.add_char buffer c;
        replacing := false)
      else if not !replacing then (
        Buffer.add_char buffer '-';
        replacing := true))
    basename;
  let trim s =
    let punctuation c = c = '.' || c = '_' || c = '-' in
    let a = ref 0 and b = ref (String.length s) in
    while !a < !b && punctuation s.[!a] do
      incr a
    done;
    while !b > !a && punctuation s.[!b - 1] do
      decr b
    done;
    String.sub s !a (!b - !a)
  in
  let name = trim (Buffer.contents buffer) in
  let name = trim (String.sub name 0 (min 128 (String.length name))) in
  if name = "" then "deco-project" else name

let render template ~basename =
  let name = project_name basename in
  let image =
    String.map (function ('a' .. 'z' | '0' .. '9') as c -> c | _ -> '-') name
    |> String.split_on_char '-'
    |> List.filter (( <> ) "")
    |> String.concat "-"
  in
  let container =
    project_name (String.sub name 0 (min 114 (String.length name)))
    ^ "-dev-container"
  in
  let values =
    [
      ("project_name", name);
      ("image_name", image ^ "-dev-image");
      ("container_name", container);
    ]
  in
  let text = template.config_template in
  let buffer = Buffer.create (String.length text) in
  let rec loop i =
    if i < String.length text then
      if i + 1 < String.length text && String.sub text i 2 = "{{" then (
        let j = String.index_from text (i + 2) '}' in
        let key = String.sub text (i + 2) (j - i - 2) in
        Buffer.add_string buffer (List.assoc key values);
        loop (j + 2))
      else (
        Buffer.add_char buffer text.[i];
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buffer
