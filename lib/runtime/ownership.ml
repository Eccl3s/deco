type conflict = { label : string; expected : string; actual : string list }

let verify ~project ~project_root labels =
  let required =
    [
      ("dev.deco.managed", "true");
      ("dev.deco.project", project);
      ("dev.deco.project-root", project_root);
    ]
  in
  let conflicts =
    List.filter_map
      (fun (label, expected) ->
        let values =
          List.filter_map
            (fun (k, v) -> if k = label then Some v else None)
            labels
        in
        if values = [ expected ] then None
        else Some { label; expected; actual = values })
      required
  in
  match conflicts with [] -> Ok () | xs -> Error xs

let describe ~kind ~reference conflicts =
  let text = Terminal_text.escape in
  let quoted s = "\"" ^ text s ^ "\"" in
  let noun, remove, key =
    match kind with
    | `Container -> ("container", "podman rm", "[container].name")
    | `Image -> ("image", "podman rmi", "[image].name")
  in
  let find label = List.find_opt (fun c -> c.label = label) conflicts in
  let summary =
    match
      ( find "dev.deco.managed",
        find "dev.deco.project",
        find "dev.deco.project-root" )
    with
    | Some _, _, _ -> "exists but was not created by Deco"
    | None, Some { actual = [ other ]; _ }, _ ->
        "belongs to Deco project " ^ quoted other
    | None, Some _, _ -> "has conflicting Deco project labels"
    | None, None, Some _ ->
        "belongs to a Deco project with the same name at another location"
    | None, None, None -> "has different ownership labels"
  in
  let found = function
    | [] -> "missing"
    | [ value ] -> "found " ^ quoted value
    | values ->
        "found " ^ String.concat ", " (List.map quoted values) ^ " (duplicated)"
  in
  let details =
    List.map
      (fun c ->
        Printf.sprintf "  %s: expected %s, %s" c.label (quoted c.expected)
          (found c.actual))
      conflicts
  in
  let rename =
    "set " ^ key ^ " in .deco/config.toml to use a different name."
  in
  let hints =
    match conflicts with
    | [ { label = "dev.deco.project-root"; actual = [ old_root ]; _ } ] ->
        [
          "  If the project was moved from " ^ text old_root
          ^ " and that copy no longer exists, remove the old " ^ noun ^ " with:";
          "    " ^ remove ^ " " ^ text reference;
          "  Otherwise, " ^ rename;
        ]
    | _ -> [ "  To keep it, " ^ rename ]
  in
  String.concat "\n"
    (((noun ^ " " ^ text reference ^ " " ^ summary) :: details) @ hints)

type identity = { uid : int; gid : int }

let identity labels =
  let parse prefix s =
    if not (String.starts_with ~prefix s) then None
    else
      let value =
        String.sub s (String.length prefix)
          (String.length s - String.length prefix)
      in
      if
        value = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') value)
      then None
      else
        match int_of_string_opt value with
        | Some n when Int64.of_int n <= 4294967294L -> Some n
        | _ -> None
  in
  match
    List.filter_map
      (fun (k, v) -> if k = "dev.deco.user-identity" then Some v else None)
      labels
  with
  | [] -> Ok None
  | [ value ] -> (
      match String.split_on_char ',' value with
      | [ u; g ] -> (
          match (parse "uid:" u, parse "gid:" g) with
          | Some uid, Some gid -> Ok (Some { uid; gid })
          | _ -> Error "Malformed user identity label")
      | _ -> Error "Malformed user identity label")
  | _ -> Error "Duplicate user identity label"
