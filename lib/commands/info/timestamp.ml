let is_leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

let days_in_month y = function
  | 2 -> if is_leap y then 29 else 28
  | 4 | 6 | 9 | 11 -> 30
  | _ -> 31

(* Days from 1970-01-01 to the given proleptic Gregorian date. *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (m + 9) mod 12 in
  let doy = (((153 * mp) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let is_digit c = c >= '0' && c <= '9'

let parse s =
  let len = String.length s in
  let digits pos n =
    if pos + n > len then None
    else
      let rec loop i acc =
        if i = pos + n then Some acc
        else if is_digit s.[i] then
          loop (i + 1) ((acc * 10) + Char.code s.[i] - Char.code '0')
        else None
      in
      loop pos 0
  in
  let char pos expected =
    pos < len && Char.lowercase_ascii s.[pos] = expected
  in
  let ( let* ) = Option.bind in
  let* year = digits 0 4 in
  let* () = if char 4 '-' then Some () else None in
  let* month = digits 5 2 in
  let* () = if char 7 '-' then Some () else None in
  let* day = digits 8 2 in
  let* () = if char 10 't' then Some () else None in
  let* hour = digits 11 2 in
  let* () = if char 13 ':' then Some () else None in
  let* minute = digits 14 2 in
  let* () = if char 16 ':' then Some () else None in
  let* second = digits 17 2 in
  let fraction, pos =
    if char 19 '.' then (
      let stop = ref 20 in
      while !stop < len && is_digit s.[!stop] do
        incr stop
      done;
      if !stop = 20 then (None, 20)
      else (float_of_string_opt ("0." ^ String.sub s 20 (!stop - 20)), !stop))
    else (Some 0., 19)
  in
  let* fraction = fraction in
  let* offset =
    if char pos 'z' && pos + 1 = len then Some 0
    else if
      pos + 6 = len && (s.[pos] = '+' || s.[pos] = '-') && char (pos + 3) ':'
    then
      let* h = digits (pos + 1) 2 in
      let* m = digits (pos + 4) 2 in
      if h > 23 || m > 59 then None
      else
        let minutes = (h * 60) + m in
        Some (if s.[pos] = '-' then -minutes else minutes)
    else None
  in
  if
    month < 1 || month > 12 || day < 1
    || day > days_in_month year month
    || hour > 23 || minute > 59 || second > 60
  then None
  else
    let seconds =
      (days_from_civil year month day * 86400)
      + (hour * 3600) + (minute * 60) + second - (offset * 60)
    in
    Some (float_of_int seconds +. fraction)

let to_rfc3339 t =
  let tm = Unix.gmtime (Float.floor t) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let age ~now t =
  let d = now -. t in
  let unit n singular =
    Printf.sprintf "%d %s%s ago" n singular (if n = 1 then "" else "s")
  in
  if d < -60. then "in the future"
  else if d < 60. then "just now"
  else if d < 3600. then unit (int_of_float (d /. 60.)) "minute"
  else if d < 86400. then unit (int_of_float (d /. 3600.)) "hour"
  else unit (int_of_float (d /. 86400.)) "day"

let to_human ~now t =
  let tm = Unix.gmtime (Float.floor t) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d UTC (%s)" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min (age ~now t)
