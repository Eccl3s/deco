let render ~header rows =
  (* One multi-line cell per column keeps a single rule under the header;
     single-line cells keep the rows aligned. *)
  let body =
    List.mapi
      (fun i _ ->
        PrintBox.text
          (String.concat "\n" (List.map (fun row -> List.nth row i) rows)))
      header
  in
  PrintBox_text.to_string_with ~style:false
    (PrintBox.frame
       (PrintBox.grid_l ~pad:(PrintBox.hpad 1) ~bars:true
          [ List.map PrintBox.line header; body ]))
  ^ "\n"
