let info = [ "podman"; "info" ]
let exists kind name = [ "podman"; kind; "exists"; "--"; name ]
let inspect kind name = [ "podman"; kind; "inspect"; "--"; name ]
