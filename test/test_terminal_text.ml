open Deco

let () =
  let check input expected =
    let actual = Terminal_text.escape input in
    if actual <> expected then
      failwith (Printf.sprintf "%S: got %S, expected %S" input actual expected)
  in
  List.iter
    (fun (input, expected) -> check input expected)
    [
      ("", "");
      ("plain /path-1_2", "plain /path-1_2");
      (* Valid non-ASCII text is kept. *)
      ("caf\xc3\xa9 \xe2\x9c\x93", "caf\xc3\xa9 \xe2\x9c\x93");
      (* C0 controls, DEL and C1 controls. *)
      ("a\027[31mb", "a\\x1b[31mb");
      ("x\ny\tz\r\000", "x\\x0ay\\x09z\\x0d\\x00");
      ("\x7f", "\\x7f");
      ("\xc2\x9b", "\\x9b");
      (* Bidirectional formatting characters. *)
      ("\xe2\x80\x8e\xe2\x80\x8f", "\\u{200e}\\u{200f}");
      ("\xe2\x80\xaa\xe2\x80\xae", "\\u{202a}\\u{202e}");
      ("\xe2\x81\xa6\xe2\x81\xa9", "\\u{2066}\\u{2069}");
      (* Neighbours of the escaped ranges are kept. *)
      ("\xc2\xa0\xe2\x80\x8d\xe2\x80\xaf", "\xc2\xa0\xe2\x80\x8d\xe2\x80\xaf");
      (* Invalid UTF-8 is escaped byte by byte. *)
      ("\xff", "\\xff");
      ("a\xe2\x80", "a\\xe2\\x80");
    ]
