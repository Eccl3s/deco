type value =
  | String of string
  | Integer of int64
  | Float of float
  | Bool of bool
  | Array of value list
  | Table of (string * value) list

exception Parse_error of string * int * int

type parser = { s : string; mutable pos : int; mutable line : int; mutable col : int }

let parse_error t msg = raise (Parse_error (msg, t.line, t.col))

let peek t = if t.pos < String.length t.s then Some t.s.[t.pos] else None

let peek_at t n =
  let i = t.pos + n in
  if i < String.length t.s then Some t.s.[i] else None

let advance t =
  if t.pos < String.length t.s then begin
    if t.s.[t.pos] = '\n' then begin
      t.line <- t.line + 1;
      t.col <- 1
    end
    else t.col <- t.col + 1;
    t.pos <- t.pos + 1
  end

let advance_n t n = for _ = 1 to n do advance t done

let skip_ws t =
  match peek t with
  | Some (' ' | '\t') -> advance t; skip_ws t
  | _ -> ()

let skip_to_eol t =
  match peek t with
  | Some '\n' | None -> ()
  | Some _ -> advance t; skip_to_eol t

let rec skip_ws_nl t =
  skip_ws t;
  match peek t with
  | Some '#' -> skip_to_eol t; skip_ws_nl t
  | Some ('\n' | '\r') -> advance t; skip_ws_nl t
  | _ -> ()

let rec skip_ws_only t =
  match peek t with
  | Some (' ' | '\t' | '\r' | '\n') -> advance t; skip_ws_only t
  | _ -> ()

let hex_value c =
  match c with
  | '0'..'9' -> Char.code c - Char.code '0'
  | 'a'..'f' -> Char.code c - Char.code 'a' + 10
  | 'A'..'F' -> Char.code c - Char.code 'A' + 10
  | _ -> -1

let parse_hex t n =
  let v = ref 0 in
  for _ = 1 to n do
    match peek t with
    | Some c when hex_value c >= 0 ->
        v := (!v * 16) + hex_value c;
        advance t
    | _ -> parse_error t "invalid unicode escape"
  done;
  !v

let add_codepoint t b cp =
  if not (Uchar.is_valid cp) then parse_error t "invalid unicode codepoint";
  Buffer.add_utf_8_uchar b (Uchar.of_int cp)

let add_escape t b =
  match peek t with
  | Some 'b' -> advance t; Buffer.add_char b '\b'
  | Some 't' -> advance t; Buffer.add_char b '\t'
  | Some 'n' -> advance t; Buffer.add_char b '\n'
  | Some 'f' -> advance t; Buffer.add_char b '\012'
  | Some 'r' -> advance t; Buffer.add_char b '\r'
  | Some '"' -> advance t; Buffer.add_char b '"'
  | Some '\\' -> advance t; Buffer.add_char b '\\'
  | Some 'u' -> advance t; add_codepoint t b (parse_hex t 4)
  | Some 'U' -> advance t; add_codepoint t b (parse_hex t 8)
  | _ -> parse_error t "invalid escape sequence"

let parse_basic_string t =
  let b = Buffer.create 16 in
  let rec loop () =
    match peek t with
    | None -> parse_error t "unterminated string"
    | Some '"' -> advance t
    | Some '\\' -> advance t; add_escape t b; loop ()
    | Some '\n' -> parse_error t "newline in string"
    | Some c -> Buffer.add_char b c; advance t; loop ()
  in
  loop ();
  Buffer.contents b

let parse_literal_string t =
  let b = Buffer.create 16 in
  let rec loop () =
    match peek t with
    | None -> parse_error t "unterminated string"
    | Some '\'' -> advance t
    | Some '\n' -> parse_error t "newline in string"
    | Some c -> Buffer.add_char b c; advance t; loop ()
  in
  loop ();
  Buffer.contents b

let count_char t c =
  let n = ref 0 in
  while peek_at t !n = Some c do incr n done;
  !n

let skip_first_newline t =
  match peek t with
  | Some '\r' ->
      advance t;
      (match peek t with Some '\n' -> advance t | _ -> ())
  | Some '\n' -> advance t
  | _ -> ()

let parse_multiline_basic_string t =
  skip_first_newline t;
  let b = Buffer.create 64 in
  let rec loop () =
    match peek t with
    | None -> parse_error t "unterminated multiline string"
    | Some '"' ->
        let n = count_char t '"' in
        if n >= 3 then begin
          advance_n t 3;
          for _ = 1 to n - 3 do Buffer.add_char b '"' done
        end
        else begin
          advance_n t n;
          for _ = 1 to n do Buffer.add_char b '"' done;
          loop ()
        end
    | Some '\\' ->
        advance t;
        (match peek t with
        | Some (' ' | '\t' | '\r' | '\n') -> skip_ws_only t
        | _ -> add_escape t b);
        loop ()
    | Some c -> Buffer.add_char b c; advance t; loop ()
  in
  loop ();
  Buffer.contents b

let parse_multiline_literal_string t =
  skip_first_newline t;
  let b = Buffer.create 64 in
  let rec loop () =
    match peek t with
    | None -> parse_error t "unterminated multiline string"
    | Some '\'' ->
        let n = count_char t '\'' in
        if n >= 3 then begin
          advance_n t 3;
          for _ = 1 to n - 3 do Buffer.add_char b '\'' done
        end
        else begin
          advance_n t n;
          for _ = 1 to n do Buffer.add_char b '\'' done;
          loop ()
        end
    | Some c -> Buffer.add_char b c; advance t; loop ()
  in
  loop ();
  Buffer.contents b

let parse_string t =
  match peek t with
  | Some '"' ->
      advance t;
      if peek t = Some '"' && peek_at t 1 = Some '"' then begin
        advance_n t 2;
        parse_multiline_basic_string t
      end
      else if peek t = Some '"' then begin
        advance t;
        ""
      end
      else parse_basic_string t
  | Some '\'' ->
      advance t;
      if peek t = Some '\'' && peek_at t 1 = Some '\'' then begin
        advance_n t 2;
        parse_multiline_literal_string t
      end
      else if peek t = Some '\'' then begin
        advance t;
        ""
      end
      else parse_literal_string t
  | _ -> parse_error t "expected a string"

let is_digit c = c >= '0' && c <= '9'

let is_bare_key_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_'
  || c = '-'

let string_for_all f s =
  let n = String.length s in
  let rec loop i = i >= n || (f s.[i] && loop (i + 1)) in
  loop 0

let read_while t f =
  let b = Buffer.create 8 in
  let rec loop () =
    match peek t with
    | Some c when f c -> Buffer.add_char b c; advance t; loop ()
    | _ -> ()
  in
  loop ();
  Buffer.contents b

let drop_underscores s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> if c <> '_' then Buffer.add_char b c) s;
  Buffer.contents b

let expect_word t w =
  String.iter
    (fun c ->
      match peek t with
      | Some c' when c' = c -> advance t
      | _ -> parse_error t ("expected '" ^ w ^ "'"))
    w

let parse_decimal t sign =
  let tok =
    read_while t (fun c ->
        is_digit c || c = '_' || c = '.' || c = 'e' || c = 'E' || c = '+' || c = '-')
  in
  let d = drop_underscores tok in
  if d = "" then parse_error t "expected a number";
  if String.contains d '.' || String.contains d 'e' || String.contains d 'E' then
    match float_of_string_opt d with
    | Some f -> Float (f *. float_of_int sign)
    | None -> parse_error t ("invalid number: " ^ tok)
  else
    match Int64.of_string_opt (if sign < 0 then "-" ^ d else d) with
    | Some i -> Integer i
    | None -> parse_error t ("invalid number (datetimes are not supported): " ^ tok)

let parse_number t =
  let sign =
    match peek t with
    | Some '+' -> advance t; 1
    | Some '-' -> advance t; -1
    | _ -> 1
  in
  match peek t with
  | Some 'i' ->
      expect_word t "inf";
      Float (if sign < 0 then neg_infinity else infinity)
  | Some 'n' ->
      expect_word t "an";
      Float nan
  | Some '0' -> (
      match peek_at t 1 with
      | Some ('x' | 'X') ->
          advance_n t 2;
          let d = drop_underscores (read_while t (fun c -> c = '_' || hex_value c >= 0)) in
          if d = "" then parse_error t "expected hexadecimal digits after 0x";
          Integer (Int64.mul (Int64.of_int sign) (Int64.of_string ("0x" ^ d)))
      | Some ('o' | 'O') ->
          advance_n t 2;
          let d =
            drop_underscores (read_while t (fun c -> c = '_' || (c >= '0' && c <= '7')))
          in
          if d = "" then parse_error t "expected octal digits after 0o";
          Integer (Int64.mul (Int64.of_int sign) (Int64.of_string ("0o" ^ d)))
      | Some ('b' | 'B') ->
          advance_n t 2;
          let d = drop_underscores (read_while t (fun c -> c = '_' || c = '0' || c = '1')) in
          if d = "" then parse_error t "expected binary digits after 0b";
          Integer (Int64.mul (Int64.of_int sign) (Int64.of_string ("0b" ^ d)))
      | _ -> parse_decimal t sign)
  | Some c when is_digit c -> parse_decimal t sign
  | _ -> parse_error t "expected a number"

let parse_key t =
  skip_ws t;
  let parse_one () =
    match peek t with
    | Some c when is_bare_key_char c -> read_while t is_bare_key_char
    | Some '"' -> advance t; parse_basic_string t
    | Some '\'' -> advance t; parse_literal_string t
    | _ -> parse_error t "expected a key"
  in
  let rec loop acc =
    let k = parse_one () in
    skip_ws t;
    match peek t with
    | Some '.' -> advance t; loop (k :: acc)
    | _ -> List.rev (k :: acc)
  in
  loop []

let rec add_to_table tbl key v =
  match tbl with
  | [] -> [ (key, v) ]
  | (k, _) :: rest when k = key -> (k, v) :: rest
  | x :: rest -> x :: add_to_table rest key v

let rec add_dotted tbl key v t =
  match key with
  | [] -> parse_error t "empty key"
  | [ k ] -> add_to_table tbl k v
  | k :: rest ->
      let child =
        match List.assoc_opt k tbl with
        | Some (Table c) -> c
        | Some _ -> parse_error t ("'" ^ k ^ "' is already defined as a value")
        | None -> []
      in
      add_to_table tbl k (Table (add_dotted child rest v t))

let rec parse_value t =
  skip_ws t;
  match peek t with
  | Some '"' | Some '\'' -> String (parse_string t)
  | Some '[' -> parse_array t
  | Some '{' -> parse_inline_table t
  | Some 't' -> expect_word t "true"; Bool true
  | Some 'f' -> expect_word t "false"; Bool false
  | Some ('+' | '-' | '0'..'9' | 'i' | 'n') -> parse_number t
  | _ -> parse_error t "expected a value"

and parse_array t =
  advance t;
  let rec loop acc =
    skip_ws_nl t;
    match peek t with
    | Some ']' -> advance t; List.rev acc
    | _ ->
        let v = parse_value t in
        skip_ws_nl t;
        match peek t with
        | Some ',' -> advance t; loop (v :: acc)
        | Some ']' -> advance t; List.rev (v :: acc)
        | _ -> parse_error t "expected ',' or ']' in array"
  in
  Array (loop [])

and parse_inline_table t =
  advance t;
  let rec loop acc =
    skip_ws t;
    match peek t with
    | Some '}' -> advance t; Table (List.rev acc)
    | _ ->
        let key = parse_key t in
        skip_ws t;
        (match peek t with
        | Some '=' -> advance t
        | _ -> parse_error t "expected '='");
        let v = parse_value t in
        let acc = add_dotted acc key v t in
        skip_ws t;
        match peek t with
        | Some ',' -> advance t; loop acc
        | Some '}' -> advance t; Table (List.rev acc)
        | _ -> parse_error t "expected ',' or '}' in inline table"
  in
  loop []

let rec ensure_path tbl path t =
  match path with
  | [] -> tbl
  | p :: rest ->
      let child =
        match List.assoc_opt p tbl with
        | Some (Table c) -> c
        | None -> []
        | Some _ -> parse_error t ("'" ^ p ^ "' is not a table")
      in
      add_to_table tbl p (Table (ensure_path child rest t))

let rec push_array_table tbl path t =
  match path with
  | [] -> parse_error t "empty table path"
  | [ name ] ->
      let arr =
        match List.assoc_opt name tbl with
        | Some (Array a) -> a
        | None -> []
        | Some _ -> parse_error t ("'" ^ name ^ "' is not an array of tables")
      in
      add_to_table tbl name (Array (arr @ [ Table [] ]))
  | p :: rest ->
      let child =
        match List.assoc_opt p tbl with
        | Some (Table c) -> c
        | None -> []
        | Some _ -> parse_error t ("'" ^ p ^ "' is not a table")
      in
      add_to_table tbl p (Table (push_array_table child rest t))

let rec get_table tbl path t =
  match path with
  | [] -> tbl
  | p :: rest -> (
      match List.assoc_opt p tbl with
      | Some (Table c) -> get_table c rest t
      | Some (Array a) -> (
          match List.rev a with
          | Table c :: _ -> get_table c rest t
          | _ -> parse_error t ("array '" ^ p ^ "' contains no tables"))
      | Some _ -> parse_error t ("'" ^ p ^ "' is not a table")
      | None -> parse_error t ("undefined table: " ^ p))

let rec replace_path tbl path new_contents =
  match path with
  | [] -> new_contents
  | p :: rest -> (
      match List.assoc_opt p tbl with
      | Some (Table c) -> add_to_table tbl p (Table (replace_path c rest new_contents))
      | Some (Array a) ->
          let rec update_last = function
            | [] -> []
            | [ Table c ] -> [ Table (replace_path c rest new_contents) ]
            | [ x ] -> [ x ]
            | x :: xs -> x :: update_last xs
          in
          add_to_table tbl p (Array (update_last a))
      | _ -> tbl)

let set_in_table root path key v t =
  let target = get_table root path t in
  replace_path root path (add_dotted target key v t)

let parse s =
  let t = { s; pos = 0; line = 1; col = 1 } in
  let rec loop root path =
    skip_ws_nl t;
    match peek t with
    | None -> root
    | Some '[' ->
        advance t;
        let is_array =
          match peek t with
          | Some '[' -> advance t; true
          | _ -> false
        in
        let path = parse_key t in
        skip_ws t;
        if is_array then begin
          match peek t with
          | Some ']' ->
              advance t;
              (match peek t with
              | Some ']' -> advance t
              | _ -> parse_error t "expected ']]'")
          | _ -> parse_error t "expected ']]'"
        end
        else
          match peek t with
          | Some ']' -> advance t
          | _ -> parse_error t "expected ']'";
        let root =
          if is_array then push_array_table root path t else ensure_path root path t
        in
        skip_ws t;
        (match peek t with
        | Some '#' -> skip_to_eol t
        | _ -> ());
        (match peek t with
        | Some ('\n' | '\r') -> advance t
        | None -> ()
        | _ -> parse_error t "expected a newline after a table header");
        loop root path
    | _ ->
        let key = parse_key t in
        skip_ws t;
        (match peek t with
        | Some '=' -> advance t
        | _ -> parse_error t "expected '='");
        let v = parse_value t in
        let root = set_in_table root path key v t in
        skip_ws t;
        (match peek t with
        | Some '#' -> skip_to_eol t
        | _ -> ());
        (match peek t with
        | Some ('\n' | '\r') -> advance t
        | None -> ()
        | _ -> parse_error t "expected a newline after a key-value pair");
        loop root path
  in
  Table (loop [] [])

let escape_string s =
  let b = Buffer.create (String.length s + 2) in
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let print_key k =
  if k <> "" && string_for_all is_bare_key_char k then k
  else "\"" ^ escape_string k ^ "\""

let rec value_to_string = function
  | String s -> "\"" ^ escape_string s ^ "\""
  | Integer i -> Int64.to_string i
  | Float f ->
      if Float.is_nan f then "nan"
      else if Float.is_infinite f then (if f > 0.0 then "inf" else "-inf")
      else Printf.sprintf "%g" f
  | Bool b -> string_of_bool b
  | Array a -> "[" ^ String.concat ", " (List.map value_to_string a) ^ "]"
  | Table tbl ->
      "{"
      ^ String.concat ", " (List.map (fun (k, v) -> print_key k ^ " = " ^ value_to_string v) tbl)
      ^ "}"

let is_table_array = function
  | Array a -> List.for_all (function Table _ -> true | _ -> false) a
  | _ -> false

let rec print_table buf prefix tbl =
  List.iter
    (fun (k, v) ->
      match v with
      | Table _ -> ()
      | a when is_table_array a -> ()
      | _ -> Buffer.add_string buf (print_key k ^ " = " ^ value_to_string v ^ "\n"))
    tbl;
  List.iter
    (fun (k, v) ->
      let child = if prefix = "" then print_key k else prefix ^ "." ^ print_key k in
      match v with
      | Table c ->
          Buffer.add_string buf ("\n[" ^ child ^ "]\n");
          print_table buf child c
      | Array a when is_table_array a ->
          List.iter
            (function
              | Table c ->
                  Buffer.add_string buf ("\n[[" ^ child ^ "]]\n");
                  print_table buf child c
              | _ -> ())
            a
      | _ -> ())
    tbl

let to_string = function
  | Table tbl ->
      let b = Buffer.create 256 in
      print_table b "" tbl;
      Buffer.contents b
  | v -> value_to_string v ^ "\n"
