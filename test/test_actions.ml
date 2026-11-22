open Deco

let () =
  assert (Actions.render_human [] = "No actions configured.\n");
  assert (Actions.render_json [] = "[]\n");
  let actions =
    [ ("build", "make"); ("long-name", "make check"); ("t", "a\027[2J\nb") ]
  in
  (* A framed table; control characters are escaped, so each action stays on
     one row. *)
  assert (
    Actions.render_human actions
    = "┌───────────┬───────────────┐\n\
       │ NAME      │ COMMAND       │\n\
       ├───────────┼───────────────┤\n\
       │ build     │ make          │\n\
       │ long-name │ make check    │\n\
       │ t         │ a\\x1b[2J\\x0ab │\n\
       └───────────┴───────────────┘\n");
  (* JSON keeps the exact command, escaped as JSON. *)
  let json = Yojson.Basic.from_string (Actions.render_json actions) in
  assert (
    json
    = `List
        (List.map
           (fun (name, command) ->
             `Assoc [ ("name", `String name); ("command", `String command) ])
           actions));
  assert (not (String.contains (Actions.render_json actions) '\027'))
