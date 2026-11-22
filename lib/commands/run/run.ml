type error = Unknown_action of string | Exec of Exec.error

let run ?execute ?read_many ?probe ?hook loaded ~tty name =
  match Run_plan.make loaded ~tty name with
  | Error (Run_plan.Unknown_action name) -> Error (Unknown_action name)
  | Error (Run_plan.Planning message) ->
      Error (Exec { Exec.cause = Exec.Planning message; started = false })
  | Ok plan ->
      Result.map_error
        (fun error -> Exec error)
        (Exec.run ?execute ?read_many ?probe ?hook loaded ~tty
           plan.Run_plan.argv)
