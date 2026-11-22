type name = Post_create | Post_start | Pre_enter | Pre_stop

let to_string = function
  | Post_create -> "post_create"
  | Post_start -> "post_start"
  | Pre_enter -> "pre_enter"
  | Pre_stop -> "pre_stop"

let configured (loaded : Config_loader.t) name =
  let hooks = loaded.effective.hooks in
  match name with
  | Post_create -> hooks.post_create
  | Post_start -> hooks.post_start
  | Pre_enter -> hooks.pre_enter
  | Pre_stop -> hooks.pre_stop

let argv (loaded : Config_loader.t) ~container command =
  Podman_command.exec ~interactive:false ~tty:false
    ~user:(User_identity.exec_user loaded.identity)
    ~workdir:loaded.effective.container.workdir ~container
    [ loaded.effective.container.shell; "-lc"; command ]

let command loaded name =
  Option.map
    (fun command ->
      let argv = argv loaded ~container:"" command in
      (* The container is the argument before the shell and its two
         arguments. *)
      let index = List.length argv - 4 in
      List.mapi
        (fun i value ->
          if i = index then Command_plan.Container_id
          else Command_plan.Literal value)
        argv)
    (configured loaded name)

let render_step ~condition name command =
  condition ^ ", run the " ^ to_string name ^ " hook:\n"
  ^ Command_plan.render_multiline
      (List.map
         (function
           | Command_plan.Literal s ->
               Command_plan.Literal (Terminal_text.escape s)
           | (Command_plan.Image_id | Command_plan.Container_id) as placeholder
             ->
               placeholder)
         command)

type runner = string list -> (Process.result, Process.error) result

type failure =
  | Exited of { hook : name; status : Unix.process_status }
  | Launch of { hook : name; error : Process.error }

let failed = function Exited { hook; _ } | Launch { hook; _ } -> hook

let failure_message = function
  | Exited { hook; status = Unix.WEXITED code } ->
      Printf.sprintf "%s hook failed with exit status %d" (to_string hook) code
  | Exited { hook; status = Unix.WSIGNALED _ | Unix.WSTOPPED _ } ->
      to_string hook ^ " hook terminated without a normal exit status"
  | Launch { hook; error } ->
      Printf.sprintf "%s hook could not be run: %s: %s" (to_string hook)
        error.operation error.message

let exit_status = function
  | Exited { status = Unix.WEXITED code; _ } when code <> 0 -> code
  | Exited _ | Launch _ -> 1

let run ?run loaded ~container_id name =
  let run =
    Option.value run ~default:(fun argv ->
        Process.run ~output:Process.Inherit ~forward_signals:true argv)
  in
  match configured loaded name with
  | None -> Ok ()
  | Some command -> (
      match run (argv loaded ~container:container_id command) with
      | Error error -> Error (Launch { hook = name; error })
      | Ok { status = Unix.WEXITED 0; _ } -> Ok ()
      | Ok { status; _ } -> Error (Exited { hook = name; status }))
