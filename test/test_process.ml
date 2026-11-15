open Deco

let () =
  if Array.length Sys.argv > 1 then
    match Sys.argv.(1) with
    | "echo" -> print_string Sys.argv.(2)
    | "large" ->
        for _ = 1 to 10000 do
          output_string stdout "0123456789";
          output_string stderr "abcdefghij"
        done
    | "exit" -> exit 7
    | "signal" -> Unix.kill (Unix.getpid ()) Sys.sigterm
    | _ -> assert false
  else
    let run args =
      match Process.run (Sys.executable_name :: args) with
      | Ok r -> r
      | Error e -> failwith e.message
    in
    let literal = "hello ; $(echo bad) ' \" world" in
    assert ((run [ "echo"; literal ]).stdout = literal);
    let r = run [ "large" ] in
    assert (String.length r.stdout = 100000 && String.length r.stderr = 100000);
    assert ((run [ "exit" ]).status = Unix.WEXITED 7);
    assert ((run [ "signal" ]).status = Unix.WSIGNALED Sys.sigterm);
    assert (Result.is_error (Process.run [ "/nonexistent/deco-test-command" ]));
    assert (Result.is_error (Process.run []));
    assert (
      match Process.run ~output:Inherit [ Sys.executable_name; "echo"; "" ] with
      | Ok r -> r.status = Unix.WEXITED 0 && r.stdout = ""
      | _ -> false)
