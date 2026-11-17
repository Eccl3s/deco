let info = [ "podman"; "info"; "--format"; "json" ]
let exists kind name = [ "podman"; kind; "exists"; "--"; name ]
let inspect kind name = [ "podman"; kind; "inspect"; "--"; name ]
