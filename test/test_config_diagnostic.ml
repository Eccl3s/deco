let () =
  let module D = Config.Diagnostic in
  List.iter
    (fun (path, expected) ->
      assert (D.to_string { path; message = "problem" } = expected))
    [
      ([], "problem");
      ([ "build"; "args"; "VERSION" ], "build.args.VERSION: problem");
      ([ "a.b" ], "\"a.b\": problem");
      ([ "" ], "\"\": problem");
      ([ "a\"b" ], "\"a\\\"b\": problem");
      ([ "a\\b" ], "\"a\\\\b\": problem");
    ];
  let diagnostic : D.t =
    { path = [ "build"; "args"; "a.b" ]; message = "problem" }
  in
  let validation : Config.Validate.error = diagnostic in
  assert (
    Config.Validate.error_to_string validation
    = Config.Decode.error_to_string (Config.Decode.Schema_error diagnostic));
  assert (
    D.compare
      { path = [ "a" ]; message = "z" }
      { path = [ "b" ]; message = "a" }
    < 0);
  assert (
    D.compare
      { path = [ "a" ]; message = "a" }
      { path = [ "a" ]; message = "b" }
    < 0);
  assert (D.compare diagnostic diagnostic = 0)

let () =
  assert (Config.Diagnostic.format_path [] = "");
  assert (
    Config.Diagnostic.format_path [ "build"; "args"; "a.b" ]
    = "build.args.\"a.b\"")
