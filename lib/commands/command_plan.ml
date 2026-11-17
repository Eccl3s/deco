type argument = Literal of string | Image_id | Container_id

let resolve ~image_id ~container_id command =
  List.map
    (function
      | Literal s -> s | Image_id -> image_id | Container_id -> container_id)
    command

let quote s =
  if
    s <> ""
    && String.for_all
         (function
           | 'a' .. 'z'
           | 'A' .. 'Z'
           | '0' .. '9'
           | '_' | '-' | '.' | '/' | ':' | '=' | ',' | '@' | '+' ->
               true
           | _ -> false)
         s
  then s
  else "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let render_command command =
  String.concat " "
    (List.map
       (function
         | Literal s -> quote s
         | Image_id -> "'<image-id>'"
         | Container_id -> "'<container-id>'")
       command)

let render_multiline command =
  let paired =
    [
      "--file";
      "--tag";
      "--target";
      "--label";
      "--build-arg";
      "--name";
      "--user";
      "--workdir";
      "--volume";
      "--";
    ]
  in
  let rec groups = function
    | [] -> []
    | (Literal flag as arg) :: value :: rest when List.mem flag paired ->
        render_command [ arg; value ] :: groups rest
    | arg :: rest -> render_command [ arg ] :: groups rest
  in
  match command with
  | executable :: subcommand :: rest -> (
      "    "
      ^ render_command [ executable; subcommand ]
      ^
      match groups rest with
      | [] -> ""
      | xs -> " \\\n      " ^ String.concat " \\\n      " xs)
  | _ -> "    " ^ render_command command
