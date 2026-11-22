let render_human = function
  | [] -> "No actions configured.\n"
  | actions ->
      Text_table.render ~header:[ "NAME"; "COMMAND" ]
        (List.map
           (fun (name, command) -> [ name; Terminal_text.escape command ])
           actions)

let render_json actions =
  Yojson.Basic.pretty_to_string
    (`List
       (List.map
          (fun (name, command) ->
            `Assoc [ ("name", `String name); ("command", `String command) ])
          actions))
  ^ "\n"
