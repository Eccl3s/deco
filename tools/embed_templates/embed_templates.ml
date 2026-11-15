let fail file message = failwith (file ^ ": " ^ message)

let check_tokens file text =
  let rec scan i =
    if i + 1 < String.length text then
      if String.sub text i 2 = "{{" then (
        let close =
          try String.index_from text (i + 2) '}'
          with Not_found -> fail file "Unterminated placeholder"
        in
        if close + 1 >= String.length text || text.[close + 1] <> '}' then
          fail file "Unterminated placeholder";
        let token = String.sub text (i + 2) (close - i - 2) in
        if
          not
            (List.mem token [ "project_name"; "image_name"; "container_name" ])
        then fail file ("Unknown placeholder " ^ token);
        scan (close + 2))
      else scan (i + 1)
  in
  scan 0

let () =
  let files = Hashtbl.create 16 in
  Array.iteri
    (fun i file ->
      if i > 0 then (
        let extension = Filename.extension file in
        if not (List.mem extension [ ".toml"; ".Containerfile" ]) then
          fail file "Unknown template extension";
        let name = Filename.basename file |> Filename.remove_extension in
        let key = (name, extension) in
        if Hashtbl.mem files key then fail file "Duplicate asset";
        let text = In_channel.with_open_bin file In_channel.input_all in
        if extension = ".toml" then check_tokens file text;
        Hashtbl.add files key (file, text)))
    Sys.argv;
  let names =
    Hashtbl.fold (fun (name, _) _ names -> name :: names) files []
    |> List.sort_uniq String.compare
  in
  let asset name ext =
    match Hashtbl.find_opt files (name, ext) with
    | Some (_, text) -> text
    | None -> fail (name ^ ext) "Missing template partner"
  in
  let entries =
    List.map
      (fun name -> (name, asset name ".Containerfile", asset name ".toml"))
      names
  in
  print_endline "let files = [";
  List.iter
    (fun (name, containerfile, toml) ->
      Printf.printf "(%S, %S, %S);\n" name containerfile toml)
    entries;
  print_endline "]"
