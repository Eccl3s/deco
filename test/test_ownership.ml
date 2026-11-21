open Deco

let project = "example"
let root = "/home/user/example"

let owned =
  [
    ("dev.deco.managed", "true");
    ("dev.deco.project", project);
    ("dev.deco.project-root", root);
  ]

let verify labels = Ownership.verify ~project ~project_root:root labels

let conflicts labels =
  match verify labels with
  | Ok () -> failwith "expected an ownership conflict"
  | Error cs -> List.map (fun c -> (c.Ownership.label, c.expected, c.actual)) cs

let replace label value labels =
  List.map (fun (k, v) -> if k = label then (k, value) else (k, v)) labels

let () =
  (* This project's labels are accepted; unrelated labels are ignored. *)
  assert (verify owned = Ok ());
  assert (verify (("io.example.other", "x") :: owned) = Ok ());

  (* A moved project, or another project with the same name elsewhere: only
     the root differs. Both cases look the same to Deco. *)
  assert (
    conflicts (replace "dev.deco.project-root" "/old/example" owned)
    = [ ("dev.deco.project-root", root, [ "/old/example" ]) ]);

  (* A different Deco project that happens to use the same resource name. *)
  assert (
    conflicts
      (owned
      |> replace "dev.deco.project" "other"
      |> replace "dev.deco.project-root" "/home/user/other")
    = [
        ("dev.deco.project", project, [ "other" ]);
        ("dev.deco.project-root", root, [ "/home/user/other" ]);
      ]);

  (* A resource Deco did not create. *)
  assert (
    conflicts []
    = [
        ("dev.deco.managed", "true", []);
        ("dev.deco.project", project, []);
        ("dev.deco.project-root", root, []);
      ]);
  assert (
    conflicts (replace "dev.deco.managed" "false" owned)
    = [ ("dev.deco.managed", "true", [ "false" ]) ]);

  (* Duplicated labels are a conflict even when one value matches. *)
  assert (
    conflicts (("dev.deco.project", "other") :: owned)
    = [ ("dev.deco.project", project, [ "other"; project ]) ]);

  (* Matching is exact: no trailing slash or case folding. *)
  assert (
    conflicts (replace "dev.deco.project-root" (root ^ "/") owned)
    = [ ("dev.deco.project-root", root, [ root ^ "/" ]) ]);
  assert (
    conflicts (replace "dev.deco.project" "Example" owned)
    = [ ("dev.deco.project", project, [ "Example" ]) ])
