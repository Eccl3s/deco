open Deco

let result ?(stdout = "") ?(stderr = "") status : Process.result =
  { status; stdout; stderr }

let ok = result (Unix.WEXITED 0)

let runner responses =
  let remaining = ref responses in
  ( (fun argv ->
      match !remaining with
      | (expected, response) :: rest ->
          assert (argv = expected);
          remaining := rest;
          response
      | [] -> failwith "Unexpected invocation"),
    fun () -> assert (!remaining = []) )

let () =
  let run, done_ =
    runner [ ([ "podman"; "info"; "--format"; "json" ], Ok ok) ]
  in
  assert (Podman.available ~run () = Ok ());
  done_ ();
  assert (
    match
      Podman.available
        ~run:(fun _ ->
          Error { Process.operation = "launch"; message = "missing" })
        ()
    with
    | Error (Podman.Unavailable _) -> true
    | _ -> false);
  assert (
    match
      Podman.available ~run:(fun _ -> Ok (result (Unix.WEXITED 125))) ()
    with
    | Error (Podman.Unavailable _) -> true
    | _ -> false);
  let inspect response =
    let run, done_ =
      runner
        [
          ([ "podman"; "image"; "exists"; "--"; "test" ], Ok ok);
          ([ "podman"; "image"; "inspect"; "--"; "test" ], Ok response);
        ]
    in
    let value = Podman.inspect_image ~run "test" in
    done_ ();
    value
  in
  assert (
    match
      inspect
        (result
           ~stdout:
             "[{\"Id\":\"abc\",\"Labels\":null,\"Config\":{\"User\":\"\",\"WorkingDir\":\"/\"},\"Extra\":true}]"
           (Unix.WEXITED 0))
    with
    | Ok (Present i) -> i.id = "abc" && i.labels = []
    | _ -> false);
  List.iter
    (fun stdout ->
      assert (
        match inspect (result ~stdout (Unix.WEXITED 0)) with
        | Error (Invalid_response _) -> true
        | _ -> false))
    [ "bad"; "[]"; "[{}]"; "[{},{}]" ];
  assert (
    match inspect (result (Unix.WEXITED 125)) with
    | Error (Runtime _) -> true
    | _ -> false);
  List.iter
    (fun code ->
      let run, done_ =
        runner
          [
            ( [ "podman"; "container"; "exists"; "--"; "test" ],
              Ok (result (Unix.WEXITED code)) );
          ]
      in
      let r = Podman.inspect_container ~run "test" in
      done_ ();
      assert (
        match (code, r) with
        | 1, Ok Absent -> true
        | 125, Error (Runtime _) -> true
        | _ -> false))
    [ 1; 125 ];
  let fixture ?(init = ",\"Init\":true") state =
    Printf.sprintf
      {|[{"Id":"cid","Image":"iid","State":{"Status":"%s"},"Config":{"Labels":{},"User":"dev","WorkingDir":"/workspace"},"HostConfig":{"UsernsMode":"keep-id:uid=1000,gid=1000"%s},"Mounts":[{"Type":"bind","Source":"/project","Destination":"/workspace","Options":["rw","rprivate"]}]}]|}
      state init
  in
  List.iter
    (fun state ->
      let run, done_ =
        runner
          [
            ([ "podman"; "container"; "exists"; "--"; "c" ], Ok ok);
            ( [ "podman"; "container"; "inspect"; "--"; "c" ],
              Ok (result ~stdout:(fixture state) (Unix.WEXITED 0)) );
          ]
      in
      assert (
        match Podman.inspect_container ~run "c" with
        | Ok (Present c) ->
            c.state = state && c.init && List.length c.mounts = 1
        | _ -> false);
      done_ ())
    [ "running"; "exited"; "created"; "paused"; "removing" ];
  let inspect_fixture stdout =
    let run, done_ =
      runner
        [
          ([ "podman"; "container"; "exists"; "--"; "c" ], Ok ok);
          ( [ "podman"; "container"; "inspect"; "--"; "c" ],
            Ok (result ~stdout (Unix.WEXITED 0)) );
        ]
    in
    let response = Podman.inspect_container ~run "c" in
    done_ ();
    response
  in
  List.iter
    (fun (init, expected) ->
      assert (
        match inspect_fixture (fixture ~init "running") with
        | Ok (Present c) -> c.init = expected
        | _ -> false))
    [
      ("", false);
      (",\"Init\":null", false);
      (",\"Init\":false", false);
      (",\"Init\":true", true);
    ];
  assert (
    match inspect_fixture (fixture ~init:",\"Init\":1" "running") with
    | Error (Invalid_response _) -> true
    | _ -> false);
  List.iter
    (fun host ->
      let json = Yojson.Basic.from_string (fixture "running") in
      let json =
        match json with
        | `List [ `Assoc fields ] ->
            `List
              [
                `Assoc
                  ((match host with
                     | None -> []
                     | Some value -> [ ("HostConfig", value) ])
                  @ List.remove_assoc "HostConfig" fields);
              ]
        | _ -> assert false
      in
      assert (
        match inspect_fixture (Yojson.Basic.to_string json) with
        | Error (Invalid_response _) -> true
        | _ -> false))
    [ None; Some `Null; Some (`String "bad") ];
  List.iter
    (fun kind ->
      let run, done_ =
        runner
          [
            ( [ "podman"; kind; "exists"; "--"; "test" ],
              Error
                { Process.operation = "launch"; message = "missing executable" }
            );
          ]
      in
      let response =
        if kind = "image" then
          Result.map (fun _ -> ()) (Podman.inspect_image ~run "test")
        else Result.map (fun _ -> ()) (Podman.inspect_container ~run "test")
      in
      done_ ();
      assert (
        match response with
        | Error (Runtime { message; _ }) ->
            message = "launch: missing executable"
        | _ -> false))
    [ "image"; "container" ];
  let labels =
    [
      ("dev.deco.managed", "true");
      ("dev.deco.project", "p");
      ("dev.deco.project-root", "/p");
    ]
  in
  let verify = Ownership.verify ~project:"p" ~project_root:"/p" in
  assert (verify labels = Ok ());
  List.iter
    (fun (key, _) ->
      assert (Result.is_error (verify (List.remove_assoc key labels)));
      assert (
        Result.is_error
          (verify ((key, "wrong") :: List.remove_assoc key labels))))
    labels;
  List.iter
    (fun (key, expected) ->
      List.iter
        (fun duplicate ->
          assert (
            match verify ((key, duplicate) :: labels) with
            | Error [ conflict ] ->
                conflict.label = key
                && conflict.expected = expected
                && conflict.actual = [ duplicate; expected ]
            | _ -> false))
        [ expected; "different" ])
    labels;
  assert (
    Ownership.identity [ ("dev.deco.user-identity", "uid:0,gid:0") ]
    = Ok (Some { Ownership.uid = 0; gid = 0 }));
  assert (Ownership.identity [] = Ok None);
  assert (
    Ownership.identity [ ("dev.deco.user-identity", "uid:1000,gid:1001") ]
    = Ok (Some { Ownership.uid = 1000; gid = 1001 }));
  List.iter
    (fun v ->
      assert (
        Result.is_error (Ownership.identity [ ("dev.deco.user-identity", v) ])))
    [
      "";
      "uid:-1,gid:1";
      "uid:4294967295,gid:1";
      "uid:1";
      "uid:x,gid:1";
      "uid:1,gid:2,extra:3";
    ];
  assert (
    Result.is_error
      (Ownership.identity
         [
           ("dev.deco.user-identity", "uid:1,gid:1");
           ("dev.deco.user-identity", "uid:1,gid:1");
         ]))

let () =
  List.iter
    (fun text ->
      assert (
        match Podman.decode_image text with
        | Ok i -> i.user = "" && i.workdir = "" && i.labels = []
        | _ -> false))
    [
      {|[{"Id":"iid","Config":{}}]|};
      {|[{"Id":"iid","Labels":null,"Config":{"User":null,"WorkingDir":null}}]|};
    ];
  assert (
    Result.is_error
      (Podman.decode_image {|[{"Id":"iid","Config":{"User":42}}]|}))

let () =
  let text =
    {|[{"Id":"cid","Image":"iid","Config":{"Labels":{}},"State":{"Status":"created"},"HostConfig":{"Init":true,"UsernsMode":"private","Annotations":{"io.podman.annotations.userns":"keep-id:uid=1000,gid=1000"},"Binds":["/tmp/test:/workspace:Z,rprivate"]},"Mounts":[{"Type":"bind","Source":"/tmp/test","Destination":"/workspace","Options":["rw"]}]}]|}
  in
  let c = Result.get_ok (Podman.decode_container text) in
  assert (c.userns = "keep-id:uid=1000,gid=1000");
  assert (List.mem "Z" (List.hd c.mounts).options)
