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
let version_json = [ "podman"; "--remote=false"; "version"; "--format"; "json" ]
let stop container = [ "podman"; "--remote=false"; "stop"; "--"; container ]

let remove_container id =
  [ "podman"; "--remote=false"; "container"; "rm"; "--"; id ]

let remove_image id =
  [ "podman"; "--remote=false"; "image"; "rm"; "--no-prune"; "--"; id ]

let list_containers =
  [
    "podman";
    "--remote=false";
    "container";
    "ls";
    "--all";
    "--no-trunc";
    "--format";
    "json";
  ]

let list_managed_containers =
  [
    "podman";
    "--remote=false";
    "container";
    "ls";
    "--all";
    "--no-trunc";
    "--filter";
    "label=dev.deco.managed=true";
    "--format";
    "json";
  ]
