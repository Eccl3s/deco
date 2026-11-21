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

let describe ?(kind = `Container) ?(reference = "example-dev-container") labels
    =
  match verify labels with
  | Ok () -> failwith "expected an ownership conflict"
  | Error cs -> Ownership.describe ~kind ~reference cs

let check name actual expected =
  if actual <> expected then
    failwith
      (Printf.sprintf "%s:\n--- got\n%s\n--- expected\n%s" name actual expected)

let () =
  (* Moved project: the only case where removal is suggested, conditionally. *)
  check "moved container"
    (describe (replace "dev.deco.project-root" "/old/example" owned))
    "container example-dev-container belongs to a Deco project with the same \
     name at another location\n\
    \  dev.deco.project-root: expected \"/home/user/example\", found \
     \"/old/example\"\n\
    \  If the project was moved from /old/example and that copy no longer \
     exists, remove the old container with:\n\
    \    podman rm example-dev-container\n\
    \  Otherwise, set [container].name in .deco/config.toml to use a different \
     name.";
  check "moved image"
    (describe ~kind:`Image ~reference:"example-dev-image:latest"
       (replace "dev.deco.project-root" "/old/example" owned))
    "image example-dev-image:latest belongs to a Deco project with the same \
     name at another location\n\
    \  dev.deco.project-root: expected \"/home/user/example\", found \
     \"/old/example\"\n\
    \  If the project was moved from /old/example and that copy no longer \
     exists, remove the old image with:\n\
    \    podman rmi example-dev-image:latest\n\
    \  Otherwise, set [image].name in .deco/config.toml to use a different \
     name.";

  (* Another project: never suggest removing it. *)
  check "other project"
    (describe
       (owned
       |> replace "dev.deco.project" "other"
       |> replace "dev.deco.project-root" "/home/user/other"))
    "container example-dev-container belongs to Deco project \"other\"\n\
    \  dev.deco.project: expected \"example\", found \"other\"\n\
    \  dev.deco.project-root: expected \"/home/user/example\", found \
     \"/home/user/other\"\n\
    \  To keep it, set [container].name in .deco/config.toml to use a \
     different name.";

  (* Not created by Deco. *)
  check "unlabelled" (describe [])
    "container example-dev-container exists but was not created by Deco\n\
    \  dev.deco.managed: expected \"true\", missing\n\
    \  dev.deco.project: expected \"example\", missing\n\
    \  dev.deco.project-root: expected \"/home/user/example\", missing\n\
    \  To keep it, set [container].name in .deco/config.toml to use a \
     different name.";

  (* Duplicated labels list every value; there is no single owner to name. *)
  check "duplicated"
    (describe (("dev.deco.project", "other") :: owned))
    "container example-dev-container has conflicting Deco project labels\n\
    \  dev.deco.project: expected \"example\", found \"other\", \"example\" \
     (duplicated)\n\
    \  To keep it, set [container].name in .deco/config.toml to use a \
     different name.";

  (* A duplicated root has no single old location, so removal is not
     suggested. *)
  check "duplicated root is not a move"
    (describe (("dev.deco.project-root", "/a") :: owned))
    "container example-dev-container belongs to a Deco project with the same \
     name at another location\n\
    \  dev.deco.project-root: expected \"/home/user/example\", found \"/a\", \
     \"/home/user/example\" (duplicated)\n\
    \  To keep it, set [container].name in .deco/config.toml to use a \
     different name.";

  (* Label values come from Podman and are untrusted. *)
  let hostile =
    describe
      (owned
      |> replace "dev.deco.project" "\027[31mevil"
      |> replace "dev.deco.project-root" "/x\n\027]0;title\007")
  in
  assert (not (String.contains hostile '\027'));
  assert (not (String.contains hostile '\007'));
  assert (
    String.starts_with
      ~prefix:
        "container example-dev-container belongs to Deco project \
         \"\\x1b[31mevil\"\n"
      hostile);
  assert (List.length (String.split_on_char '\n' hostile) = 4);
  let hostile_moved =
    describe (replace "dev.deco.project-root" "/old\n\027[2J" owned)
  in
  assert (not (String.contains hostile_moved '\027'));
  assert (List.length (String.split_on_char '\n' hostile_moved) = 5)
