type t = { path : string list; message : string }

let compare a b =
  let order = Stdlib.compare a.path b.path in
  if order = 0 then String.compare a.message b.message else order

let to_string { path; message } =
  let component s =
    if
      s <> ""
      && String.for_all
           (function
             | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
             | _ -> false)
           s
    then s
    else Printf.sprintf "%S" s
  in
  match path with
  | [] -> message
  | _ -> String.concat "." (List.map component path) ^ ": " ^ message
