let info = [ "podman"; "--remote=false"; "info"; "--format"; "json" ]

let exists kind name =
  [ "podman"; "--remote=false"; kind; "exists"; "--"; name ]

let inspect kind name =
  [ "podman"; "--remote=false"; kind; "inspect"; "--"; name ]

let start container = [ "podman"; "--remote=false"; "start"; "--"; container ]

let exec ~tty ~user ~workdir ~container command =
  [ "podman"; "--remote=false"; "exec"; "--interactive" ]
  @ (if tty then [ "--tty" ] else [])
  @ (match user with None -> [] | Some value -> [ "--user"; value ])
  @ (match workdir with None -> [] | Some value -> [ "--workdir"; value ])
  @ [ "--"; container ] @ command

let version = [ "podman"; "--remote=false"; "version" ]
