let label = "dev.deco.create-digest"
let fields (_ : Config_loader.t) = []

(* Each pair is its key then its value, each prefixed with its length as a
   64-bit big-endian integer, so no encoding is a prefix of a different one. *)
let digest pairs =
  let pairs = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs in
  let rec unique = function
    | (a, _) :: ((b, _) :: _ as rest) ->
        if a = b then invalid_arg ("Create_settings.digest: duplicate key " ^ a)
        else unique rest
    | _ -> ()
  in
  unique pairs;
  let buffer = Buffer.create 64 in
  let field data =
    Buffer.add_int64_be buffer (Int64.of_int (String.length data));
    Buffer.add_string buffer data
  in
  List.iter
    (fun (key, value) ->
      field key;
      field value)
    pairs;
  "blake2b-256:" ^ Digest.BLAKE256.(to_hex (string (Buffer.contents buffer)))

let of_loaded loaded = digest (fields loaded)
