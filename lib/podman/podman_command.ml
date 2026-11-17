let info = [ "podman"; "info"; "--format"; "json" ]
let exists kind name = [ "podman"; kind; "exists"; "--"; name ]
let inspect kind name = [ "podman"; kind; "inspect"; "--"; name ]
let start container = [ "podman"; "start"; "--"; container ]

let exec ~tty ~user ~workdir ~container command =
  [ "podman"; "exec"; "--interactive" ]
  @ (if tty then [ "--tty" ] else [])
  @ (match user with None -> [] | Some value -> [ "--user"; value ])
  @ (match workdir with None -> [] | Some value -> [ "--workdir"; value ])
  @ [ "--"; container ] @ command
