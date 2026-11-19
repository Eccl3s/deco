let interactive () =
  Unix.isatty Unix.stdin && Unix.isatty Unix.stdout
  && Sys.getenv_opt "NO_COLOR" = None
  && Sys.getenv_opt "TERM" <> Some "dumb"

let dots () =
  String.make (1 + (int_of_float (Unix.gettimeofday () *. 3.) mod 3)) '.'

let blue text = "\027[34m" ^ text ^ "\027[0m"

let run ~image argv =
  if not (interactive ()) then
    Deco.Process.run ~output:Deco.Process.Inherit argv
  else
    let path = Filename.temp_file "deco-build-" ".log" in
    let log = open_out_bin path in
    let old = Unix.tcgetattr Unix.stdin in
    let expanded = ref false
    and rows = ref 0
    and tail = ref ""
    and last = ref 0. in
    let clear () =
      if !rows > 0 then (
        Printf.printf "\027[%dA\027[J" !rows;
        rows := 0)
    in
    let replay () =
      flush log;
      clear ();
      print_string "\027[34m";
      In_channel.with_open_bin path (fun ch ->
          try
            while true do
              output_char stdout (input_char ch)
            done
          with End_of_file -> ());
      print_string "\027[0m";
      flush stdout;
      expanded := true
    in
    let clean chunk =
      String.map
        (fun c ->
          if
            c = '\n' || c = '\t'
            || (Char.code c >= 32 && Char.code c <> 127 && c <> '\027')
          then c
          else '?')
        chunk
    in
    let draw () =
      if (not !expanded) && Unix.gettimeofday () -. !last > 0.1 then (
        last := Unix.gettimeofday ();
        clear ();
        let lines = String.split_on_char '\n' !tail in
        let rec drop n xs =
          if n <= 0 then xs
          else match xs with [] -> [] | _ :: rest -> drop (n - 1) rest
        in
        let lines = drop (List.length lines - 10) lines in
        Printf.printf "[Building] %s %-3s\n" image (dots ());
        List.iter
          (fun line ->
            Printf.printf "%s\n"
              (blue
                 (if String.length line > 70 then String.sub line 0 70 else line)))
          lines;
        for _ = List.length lines to 9 do
          print_newline ()
        done;
        print_endline "Press t to show the full log";
        rows := 12;
        flush stdout)
    in
    Fun.protect
      ~finally:(fun () ->
        clear ();
        Unix.tcsetattr Unix.stdin Unix.TCSANOW old;
        close_out_noerr log;
        Sys.remove path;
        flush stdout)
      (fun () ->
        Unix.tcsetattr Unix.stdin Unix.TCSANOW
          {
            old with
            Unix.c_icanon = false;
            c_echo = false;
            c_vmin = 0;
            c_vtime = 0;
          };
        draw ();
        let result =
          Deco.Process.run_stream argv
            ~on_chunk:(fun chunk ->
              let chunk = clean chunk in
              output_string log chunk;
              if !expanded then (
                print_string (blue chunk);
                flush stdout)
              else (
                tail := !tail ^ chunk;
                let lines = String.split_on_char '\n' !tail in
                let rec take n xs =
                  if List.length xs <= n then xs
                  else match xs with [] -> [] | _ :: rest -> take n rest
                in
                tail := String.concat "\n" (take 10 lines);
                draw ()))
            ~poll:(fun () ->
              let ready, _, _ = Unix.select [ Unix.stdin ] [] [] 0. in
              (if ready <> [] then
                 let b = Bytes.create 64 in
                 let n = Unix.read Unix.stdin b 0 64 in
                 if
                   (not !expanded)
                   && String.contains (Bytes.sub_string b 0 n) 't'
                 then replay ());
              draw ())
        in
        (match result with
        | Ok { Deco.Process.status = Unix.WEXITED 0; _ } ->
            clear ();
            print_endline "[Building] Complete"
        | Ok
            {
              Deco.Process.status =
                Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _;
              _;
            }
        | Error _ ->
            if not !expanded then replay ());
        result)

type status = {
  begin_stage : unit -> unit;
  tick : unit -> unit;
  finish : bool -> unit;
}

let status ~label ~image =
  let active = ref false and last = ref 0. in
  let tick () =
    if !active && interactive () && Unix.gettimeofday () -. !last >= 0.1 then (
      last := Unix.gettimeofday ();
      Printf.printf "\r\027[2K[%s] %s %-3s" label image (dots ());
      flush stdout)
  in
  let begin_stage () =
    if not !active then (
      active := true;
      tick ())
  in
  let finish success =
    if !active then (
      if interactive () then (
        if success then Printf.printf "\r\027[2K[%s] Complete\n" label
        else Printf.printf "\r\027[2K[%s] Failed %s\n" label image;
        flush stdout);
      active := false)
  in
  { begin_stage; tick; finish }

type runners = {
  execute :
    Deco.Process.output ->
    string list ->
    (Deco.Process.result, Deco.Process.error) result;
  read_many :
    string list list -> (Deco.Process.result, Deco.Process.error) result list;
  close : bool -> unit;
}

let runners ~label ~image =
  let status = status ~label ~image in
  let execute output argv =
    match output with
    | Deco.Process.Inherit ->
        (* The status stage begins at create or start, not straight after the
           build, so callers can print lines between the two. *)
        run ~image argv
    | Deco.Process.Capture ->
        (match argv with
        | "podman" :: "--remote=false" :: ("create" | "start") :: _ ->
            status.begin_stage ()
        | _ -> ());
        Deco.Process.run ~output ~poll:status.tick argv
  in
  let read_many commands =
    Deco.Process.run_many ~forward_signals:true ~poll:status.tick commands
  in
  { execute; read_many; close = status.finish }
