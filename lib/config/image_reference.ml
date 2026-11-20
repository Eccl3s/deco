(* Syntax follows https://github.com/containers/image/blob/main/docker/reference/regexp.go
   Length follows https://github.com/containers/image/blob/main/docker/reference/reference.go
   No short-name normalization or registry lookup is performed. *)
let lower = function 'a' .. 'z' | '0' .. '9' -> true | _ -> false
let alnum = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | _ -> false

let digits s =
  s <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) s

let component s =
  let n = String.length s in
  let rec word i = if i < n && lower s.[i] then word (i + 1) else separator i
  and separator i =
    if i = n then true
    else
      let next =
        match s.[i] with
        | '.' -> i + 1
        | '_' -> if i + 1 < n && s.[i + 1] = '_' then i + 2 else i + 1
        | '-' ->
            let rec skip j = if j < n && s.[j] = '-' then skip (j + 1) else j in
            skip i
        | _ -> n
      in
      next < n && lower s.[next] && word (next + 1)
  in
  n > 0 && lower s.[0] && word 1

let host s =
  List.for_all
    (fun label ->
      let n = String.length label in
      n > 0
      && alnum label.[0]
      && alnum label.[n - 1]
      && String.for_all (fun c -> alnum c || c = '-') label)
    (String.split_on_char '.' s)

let registry s =
  match String.split_on_char ':' s with
  | [ hostname ] -> host hostname
  | [ hostname; port ] -> host hostname && digits port
  | _ -> false

let check_name name =
  if String.contains name '[' || String.contains name ']' then
    Error "IPv6 registries are not supported"
  else if String.contains name '@' then
    Error "Image repository must not contain a digest"
  else if String.length name > 255 then
    Error "Image repository must not exceed 255 ASCII bytes"
  else
    let parts = String.split_on_char '/' name in
    let domain, path =
      match parts with
      | first :: (_ :: _ as rest)
        when first = "localhost" || String.contains first '.'
             || String.contains first ':' ->
          (Some first, rest)
      | _ -> (None, parts)
    in
    if List.exists (fun part -> String.contains part ':') path then
      Error "Image repository must not contain a tag; set image.tag separately"
    else if
      (not (List.for_all component path))
      || not (Option.fold ~none:true ~some:registry domain)
    then
      Error
        "Expected a lowercase image repository with valid components and \
         optional DNS/IPv4 registry and numeric port"
    else Ok ()

let check_tag tag =
  let n = String.length tag in
  if
    n >= 1 && n <= 128
    && (alnum tag.[0] || tag.[0] = '_')
    && String.for_all (fun c -> alnum c || c = '_' || c = '.' || c = '-') tag
  then Ok ()
  else
    Error
      "Expected a 1-128 character ASCII image tag matching \
       [A-Za-z0-9_][A-Za-z0-9_.-]*"
