let () =
  let metadata = Sys.argv.(1) in
  let version =
    try
      let rec find_root directory =
        let marker = Filename.concat directory ".git" in
        let valid =
          try
            Sys.is_directory marker
            || String.starts_with ~prefix:"gitdir:"
                 (In_channel.with_open_bin marker In_channel.input_all)
          with Sys_error _ -> false
        in
        if valid then directory
        else
          let parent = Filename.dirname directory in
          if parent = directory then raise Not_found else find_root parent
      in
      let root = find_root (Sys.getcwd ()) in
      let channel =
        Unix.open_process_args_in "git"
          [| "git"; "-C"; root; "describe"; "--tags"; "--always"; "--dirty" |]
      in
      let text = In_channel.input_all channel |> String.trim in
      match Unix.close_process_in channel with
      | Unix.WEXITED 0 -> text
      | _ -> ""
    with Unix.Unix_error _ | Not_found -> ""
  in
  let version =
    if version = "" then metadata
    else if
      String.length version > 1
      && version.[0] = 'v'
      && version.[1] >= '0'
      && version.[1] <= '9'
    then String.sub version 1 (String.length version - 1)
    else version
  in
  if
    version = "" || version = "n/a" || version = "unknown"
    || String.contains version '%'
  then (
    prerr_endline
      "Missing package version: build from a Git checkout or embed (version \
       RELEASE) in dune-project and regenerate opam metadata.";
    exit 1);
  Out_channel.with_open_bin Sys.argv.(2) (fun channel ->
      output_string channel version);
  Printf.printf "let value = %S\n" version
