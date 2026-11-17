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
