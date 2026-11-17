type runner = string list -> (Process.result, Process.error) result

type error =
  | Unavailable of string
  | Runtime of { operation : string; message : string }
  | Invalid_response of { operation : string; message : string }

type 'a presence = Absent | Present of 'a
type labels = (string * string) list
type image = { id : string; labels : labels; user : string; workdir : string }

type mount = {
  kind : string;
  source : string;
  destination : string;
  options : string list;
}

type container = {
  id : string;
  labels : labels;
  state : string;
  image_id : string;
  user : string;
  userns : string;
  workdir : string;
  init : bool;
  mounts : mount list;
}

let default_run argv = Process.run argv

let message (r : Process.result) =
  let status =
    match r.status with
    | Unix.WEXITED n -> Printf.sprintf "exit %d" n
    | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
    | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n
  in
  status ^ if r.stderr = "" then "" else ": " ^ String.trim r.stderr

let info ?(run = default_run) () =
  match run Podman_command.info with
  | Ok ({ status = Unix.WEXITED 0; _ } as r) -> Ok r.stdout
  | Ok r -> Error (Unavailable (message r))
  | Error e -> Error (Unavailable (e.operation ^ ": " ^ e.message))

let available ?run () = Result.map (fun _ -> ()) (info ?run ())

let field name = function
  | `Assoc xs -> (
      match List.assoc_opt name xs with
      | Some x -> x
      | None -> failwith ("Missing " ^ name))
  | _ -> failwith "Expected object"

let string = function `String s -> s | _ -> failwith "Expected string"
let boolean = function `Bool b -> b | _ -> failwith "Expected boolean"
let list = function `List xs -> xs | _ -> failwith "Expected array"

let labels value =
  match value with
  | `Null -> []
  | `Assoc xs -> List.map (fun (k, v) -> (k, string v)) xs
  | _ -> failwith "Expected labels object"

let optional name default decode = function
  | `Assoc xs -> (
      match List.assoc_opt name xs with
      | None | Some `Null -> default
      | Some value -> decode value)
  | _ -> failwith "Expected object"

let image json : image =
  let config = field "Config" json in
  {
    id = string (field "Id" json);
    labels = optional "Labels" [] labels json;
    user = optional "User" "" string config;
    workdir = optional "WorkingDir" "" string config;
  }

let mount json =
  {
    kind = string (field "Type" json);
    source = string (field "Source" json);
    destination = string (field "Destination" json);
    options = List.map string (list (field "Options" json));
  }

let container json =
  let config = field "Config" json and host = field "HostConfig" json in
  {
    id = string (field "Id" json);
    labels = labels (field "Labels" config);
    state = string (field "Status" (field "State" json));
    image_id = string (field "Image" json);
    user = optional "User" "" string config;
    userns =
      (let mode = string (field "UsernsMode" host) in
       let annotations = optional "Annotations" [] labels host in
       match
         (mode, List.assoc_opt "io.podman.annotations.userns" annotations)
       with
       | "private", Some requested
         when String.starts_with ~prefix:"keep-id:" requested ->
           requested
       | _ -> mode);
    workdir = optional "WorkingDir" "" string config;
    init =
      (match host with
      | `Assoc xs -> (
          match List.assoc_opt "Init" xs with
          | None | Some `Null -> false
          | Some value -> boolean value)
      | _ -> failwith "Expected object");
    mounts =
      List.map
        (fun raw ->
          let m = mount raw in
          let binds =
            optional "Binds" [] (fun v -> List.map string (list v)) host
          in
          let policies =
            List.filter_map
              (fun bind ->
                match String.split_on_char ':' bind with
                | [ source; target; options ]
                  when source = m.source && target = m.destination ->
                    Some (String.split_on_char ',' options)
                | _ -> None)
              binds
          in
          match policies with
          | [ options ] ->
              {
                m with
                options =
                  m.options @ List.filter (fun x -> x = "z" || x = "Z") options;
              }
          | [] -> m
          | _ -> failwith "Ambiguous bind metadata")
        (list (field "Mounts" json));
  }

let inspect (run : runner) kind decode name =
  let operation = kind ^ " inspect" in
  let invoke args =
    match run args with
    | Ok r -> Ok r
    | Error e ->
        Error (Runtime { operation; message = e.operation ^ ": " ^ e.message })
  in
  match invoke (Podman_command.exists kind name) with
  | Error e -> Error e
  | Ok { status = Unix.WEXITED 1; _ } -> Ok Absent
  | Ok { status = Unix.WEXITED 0; _ } -> (
      match invoke (Podman_command.inspect kind name) with
      | Error e -> Error e
      | Ok ({ status = Unix.WEXITED 0; _ } as r) -> (
          try
            match Yojson.Basic.from_string r.stdout with
            | `List [ json ] -> Ok (Present (decode json))
            | _ ->
                Error
                  (Invalid_response
                     { operation; message = "Expected one inspection object" })
          with Failure message | Yojson.Json_error message ->
            Error (Invalid_response { operation; message }))
      | Ok r -> Error (Runtime { operation; message = message r }))
  | Ok r -> Error (Runtime { operation; message = message r })

let inspect_image ?(run = default_run) name = inspect run "image" image name

let inspect_container ?(run = default_run) name =
  inspect run "container" container name

let decode_image text =
  try
    match Yojson.Basic.from_string text with
    | `List [ json ] -> Ok (image json)
    | _ -> Error "Expected one image"
  with Failure e | Yojson.Json_error e -> Error e

let decode_container text =
  try
    match Yojson.Basic.from_string text with
    | `List [ json ] -> Ok (container json)
    | _ -> Error "Expected one container"
  with Failure e | Yojson.Json_error e -> Error e
