let escape text =
  let buffer = Buffer.create (String.length text) in
  let rec loop i =
    if i < String.length text then (
      let decoded = String.get_utf_8_uchar text i in
      let length = Uchar.utf_decode_length decoded in
      (if not (Uchar.utf_decode_is_valid decoded) then
         for j = i to i + length - 1 do
           Printf.bprintf buffer "\\x%02x" (Char.code text.[j])
         done
       else
         let code = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
         if
           code < 0x20
           || (code >= 0x7f && code <= 0x9f)
           || (code >= 0x200e && code <= 0x200f)
           || (code >= 0x202a && code <= 0x202e)
           || (code >= 0x2066 && code <= 0x2069)
         then
           if code <= 0xff then Printf.bprintf buffer "\\x%02x" code
           else Printf.bprintf buffer "\\u{%04x}" code
         else Buffer.add_string buffer (String.sub text i length));
      loop (i + length))
  in
  loop 0;
  Buffer.contents buffer
