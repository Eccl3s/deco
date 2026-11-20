open Deco

let entry ?project ?project_root ?container ?(state = "running")
    ?(image = Some "localhost/i:latest") ?(image_id = Some "iid") id =
  {
    Managed_list.project;
    project_root;
    container;
    container_id = id;
    state;
    image;
    image_id;
  }

let ids entries = List.map (fun e -> e.Managed_list.container_id) entries

(* Labels and the first name become entry fields; other labels are ignored. *)
let () =
  let listed =
    {
      Podman.id = "cid";
      names = [ "first"; "second" ];
      state = "exited";
      image = Some "localhost/i:latest";
      image_id = Some "iid";
      labels =
        [
          ("dev.deco.managed", "true");
          ("dev.deco.project", "p");
          ("dev.deco.project-root", "/r");
          ("other", "x");
        ];
    }
  in
  assert (
    Managed_list.of_container listed
    = entry ~project:"p" ~project_root:"/r" ~container:"first" ~state:"exited"
        "cid");
  let bare =
    Managed_list.of_container { listed with names = []; labels = [] }
  in
  assert (bare.project = None && bare.project_root = None);
  assert (bare.container = None)

(* Project, then container, then ID; byte-wise; missing values last. *)
let () =
  let sorted =
    Managed_list.sort
      [
        entry ~container:"a" "1";
        entry ~project:"b" ~container:"a" "2";
        entry ~project:"a" "3";
        entry ~project:"a" ~container:"b" "4";
        entry ~project:"B" ~container:"z" "5";
        entry ~project:"a" ~container:"a" "7";
        entry ~project:"a" ~container:"a" "6";
      ]
  in
  assert (ids sorted = [ "5"; "6"; "7"; "4"; "3"; "2"; "1" ])

(* Empty results print a message rather than an empty table. *)
let () =
  assert (Managed_list.render_human [] = "No Deco-managed containers.\n");
  assert (Managed_list.render_json [] = "[]\n")

let () =
  let table =
    Managed_list.render_human
      [
        entry ~project:"my-project" ~project_root:"/home/user/my-project"
          ~container:"my-project-dev-container"
          ~image:(Some "localhost/my-project-dev-image:latest") "1";
        entry ~project:"ünï" ~container:"c" ~state:"" ~image:None "2";
      ]
  in
  let expected =
    String.concat "\n"
      [
        "┌────────────┬──────────────────────────┬─────────┬───────────────────────────────────────┬───────────────────────┐";
        "│ PROJECT    │ CONTAINER                │ STATE   │ \
         IMAGE                                 │ PROJECT ROOT          │";
        "├────────────┼──────────────────────────┼─────────┼───────────────────────────────────────┼───────────────────────┤";
        "│ my-project │ my-project-dev-container │ running │ \
         localhost/my-project-dev-image:latest │ /home/user/my-project │";
        "│ ünï        │ c                        │ -       │ \
         -                                     │ -                     │";
        "└────────────┴──────────────────────────┴─────────┴───────────────────────────────────────┴───────────────────────┘";
        "";
      ]
  in
  if table <> expected then (
    print_string table;
    assert false);
  assert (not (String.contains table '\027'))

(* Values cannot inject terminal sequences or break rows. *)
let () =
  let table =
    Managed_list.render_human
      [
        entry ~project:"a\027[31mb" ~container:"x\ny"
          ~project_root:"r\xc2\x9b\xe2\x80\xae\xff" ~state:"s\tt" "1";
      ]
  in
  assert (not (String.contains table '\027'));
  assert (not (String.contains table '\t'));
  List.iter
    (fun fragment ->
      let rec found i =
        i + String.length fragment <= String.length table
        && (String.sub table i (String.length fragment) = fragment
           || found (i + 1))
      in
      assert (found 0))
    [ "a\\x1b[31mb"; "x\\x0ay"; "s\\x09t"; "r\\x9b\\u{202e}\\xff" ];
  (* Five table lines: top rule, header, rule, one row, bottom rule. *)
  assert (List.length (String.split_on_char '\n' (String.trim table)) = 5)

let () =
  let json =
    Managed_list.render_json
      [
        entry ~project:"p" ~project_root:"/r" ~container:"c" "cid";
        entry ~image:None ~image_id:None ~state:"created" "bare";
      ]
  in
  assert (String.ends_with ~suffix:"]\n" json);
  assert (not (String.ends_with ~suffix:"\n\n" json));
  let open Yojson.Basic in
  assert (
    from_string json
    = `List
        [
          `Assoc
            [
              ("project", `String "p");
              ("project_root", `String "/r");
              ("container", `String "c");
              ("container_id", `String "cid");
              ("state", `String "running");
              ("image", `String "localhost/i:latest");
              ("image_id", `String "iid");
            ];
          `Assoc
            [
              ("project", `Null);
              ("project_root", `Null);
              ("container", `Null);
              ("container_id", `String "bare");
              ("state", `String "created");
              ("image", `Null);
              ("image_id", `Null);
            ];
        ])

(* Availability is checked first; listing results are sorted. *)
let () =
  let calls = ref [] in
  let run argv =
    calls := argv :: !calls;
    if argv = Podman_command.version then
      Ok { Process.status = Unix.WEXITED 0; stdout = ""; stderr = "" }
    else if argv = Podman_command.list_managed_containers then
      Ok
        {
          Process.status = Unix.WEXITED 0;
          stdout =
            {|[{"Id":"2","Names":["b"],"State":"running","Image":"i","ImageID":"i","Labels":{"dev.deco.project":"p"}},
               {"Id":"1","Names":["a"],"State":"exited","Image":"i","ImageID":"i","Labels":{"dev.deco.project":"p"}}]|};
          stderr = "";
        }
    else failwith "Unexpected invocation"
  in
  (match Managed_list.run ~run () with
  | Ok entries -> assert (ids entries = [ "1"; "2" ])
  | Error _ -> failwith "Expected a listing");
  assert (
    List.rev !calls
    = [ Podman_command.version; Podman_command.list_managed_containers ])

(* Errors pass through unchanged; an unavailable Podman is never listed. *)
let () =
  let calls = ref 0 in
  let run _ =
    incr calls;
    Error
      { Process.operation = "launch"; message = "podman: command not found" }
  in
  (match Managed_list.run ~run () with
  | Error (Podman.Unavailable _) -> ()
  | _ -> failwith "Expected Podman to be unavailable");
  assert (!calls = 1);
  let run argv =
    if argv = Podman_command.version then
      Ok { Process.status = Unix.WEXITED 0; stdout = ""; stderr = "" }
    else Ok { Process.status = Unix.WEXITED 0; stdout = "nope"; stderr = "" }
  in
  match Managed_list.run ~run () with
  | Error (Podman.Invalid_response _) -> ()
  | _ -> failwith "Expected an invalid response"
