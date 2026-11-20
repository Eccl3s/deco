open Deco

let () =
  let parse s = Timestamp.parse s in
  let exact s expected =
    match parse s with
    | Some t when t = expected -> ()
    | Some t -> failwith (Printf.sprintf "%s: got %f" s t)
    | None -> failwith (s ^ ": rejected")
  in
  (* The epoch, Z and offsets in both directions. *)
  exact "1970-01-01T00:00:00Z" 0.;
  exact "1969-12-31T23:59:59Z" (-1.);
  exact "2026-11-20T08:39:25Z" 1795163965.;
  exact "2026-11-20t08:39:25z" 1795163965.;
  exact "2026-11-20T09:39:25+01:00" 1795163965.;
  exact "2026-11-20T03:09:25-05:30" 1795163965.;
  exact "2026-11-21T00:09:25+15:30" 1795163965.;
  (* Fractional seconds are kept. *)
  (match parse "2026-11-20T08:39:25.440792071Z" with
  | Some t -> assert (Float.abs (t -. 1795163965.440792071) < 1e-5)
  | None -> assert false);
  exact "2026-11-20T08:39:25.5+00:00" 1795163965.5;
  (* Leap years. *)
  exact "2024-02-29T12:00:00Z" 1709208000.;
  assert (parse "2000-02-29T00:00:00Z" <> None);
  List.iter
    (fun s -> if parse s <> None then failwith (s ^ ": accepted"))
    [
      "2023-02-29T00:00:00Z";
      "1900-02-29T00:00:00Z";
      "";
      "2026-11-20";
      "2026-11-20T08:39:25";
      "2026-11-20 08:39:25Z";
      "2026-13-01T00:00:00Z";
      "2026-00-01T00:00:00Z";
      "2026-04-31T00:00:00Z";
      "2026-11-00T00:00:00Z";
      "2026-11-20T24:00:00Z";
      "2026-11-20T08:60:00Z";
      "2026-11-20T08:39:61Z";
      "2026-11-20T08:39:25.Z";
      "2026-11-20T08:39:25ZZ";
      "2026-11-20T08:39:25+0100";
      "2026-11-20T08:39:25+01:00 ";
      "2026-11-20T08:39:25+24:00";
      "2026-11-20T08:39:25+01:60";
      "2026-1x-20T08:39:25Z";
      "+026-11-20T08:39:25Z";
    ];
  (* JSON form: UTC, whole seconds, fractions truncated. *)
  assert (Timestamp.to_rfc3339 0. = "1970-01-01T00:00:00Z");
  assert (Timestamp.to_rfc3339 1795163965.9 = "2026-11-20T08:39:25Z");
  assert (Timestamp.to_rfc3339 (-0.5) = "1969-12-31T23:59:59Z");
  assert (Timestamp.to_rfc3339 1709208000. = "2024-02-29T12:00:00Z");
  (* Human form and age boundaries. *)
  let created = 1794388442. in
  let human offset = Timestamp.to_human ~now:(created +. offset) created in
  assert (human (9. *. 86400.) = "2026-11-11 09:14 UTC (9 days ago)");
  List.iter
    (fun (offset, age) ->
      let expected = "2026-11-11 09:14 UTC (" ^ age ^ ")" in
      if human offset <> expected then
        failwith (Printf.sprintf "%f: %s" offset (human offset)))
    [
      (-61., "in the future");
      (-60., "just now");
      (0., "just now");
      (59.9, "just now");
      (60., "1 minute ago");
      (119., "1 minute ago");
      (120., "2 minutes ago");
      (3599., "59 minutes ago");
      (3600., "1 hour ago");
      (86399., "23 hours ago");
      (86400., "1 day ago");
      (172800., "2 days ago");
      (400. *. 86400., "400 days ago");
    ]
