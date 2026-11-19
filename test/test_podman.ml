open Deco

let result ?(stdout = "") ?(stderr = "") status : Process.result =
  { status; stdout; stderr }

let ok = result (Unix.WEXITED 0)

let runner responses =
  (* Expand resource-presence fixtures into the inspect-first protocol. *)
  let rec inspection_script = function
    | (([ p; flag; kind; "exists"; sep; name ], response) as original) :: rest
      -> (
        let command = [ p; flag; kind; "inspect"; sep; name ] in
        match (response, rest) with
        | Error e, _ -> (command, Error e) :: inspection_script rest
        | _, (expected, (Ok r as inspected)) :: tail when expected = command ->
            (expected, inspected)
            ::
            (if r.Process.status = Unix.WEXITED 0 then inspection_script tail
             else original :: inspection_script tail)
        | _, _ ->
            (command, Ok (result (Unix.WEXITED 125)))
            :: original :: inspection_script rest)
    | item :: rest -> item :: inspection_script rest
    | [] -> []
  in
  let responses = inspection_script responses in
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
  let run, done_ = runner [ (Podman_command.version, Ok ok) ] in
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
          ( [ "podman"; "--remote=false"; "image"; "exists"; "--"; "test" ],
            Ok ok );
          ( [ "podman"; "--remote=false"; "image"; "inspect"; "--"; "test" ],
            Ok response );
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
            ( [ "podman"; "--remote=false"; "container"; "exists"; "--"; "test" ],
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
            ( [ "podman"; "--remote=false"; "container"; "exists"; "--"; "c" ],
              Ok ok );
            ( [ "podman"; "--remote=false"; "container"; "inspect"; "--"; "c" ],
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
          ( [ "podman"; "--remote=false"; "container"; "exists"; "--"; "c" ],
            Ok ok );
          ( [ "podman"; "--remote=false"; "container"; "inspect"; "--"; "c" ],
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
            ( [ "podman"; "--remote=false"; kind; "exists"; "--"; "test" ],
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

let () =
  List.iter
    (fun text -> assert (Container_runtime.selinux_enabled text))
    [ ""; "{}"; "null"; "{\"host\":{\"security\":{\"selinuxEnabled\":true}}}" ];
  assert (
    not
      (Container_runtime.selinux_enabled
         "{\"host\":{\"security\":{\"selinuxEnabled\":false}}}"));
  let run, done_ =
    runner
      [
        ( Podman_command.info,
          Ok
            (result
               ~stdout:"{\"host\":{\"security\":{\"selinuxEnabled\":false}}}"
               (Unix.WEXITED 0)) );
      ]
  in
  assert (Container_runtime.availability ~run () = Ok false);
  done_ ();
  assert (
    Result.is_error
      (Container_runtime.availability
         ~run:(fun _ -> Ok (result (Unix.WEXITED 1)))
         ()))

let () =
  List.iter
    (fun state -> assert (Container_runtime.supported_state state))
    [ "running"; "created"; "configured"; "exited"; "stopped" ];
  List.iter
    (fun state -> assert (not (Container_runtime.supported_state state)))
    [ ""; "paused"; "unknown"; "removing" ]

let () =
  let root = Filename.temp_file "deco-selinux" "" in
  Unix.unlink root;
  assert (Container_runtime.local_selinux ~root () = Some false);
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink (Filename.concat root "enforce")
       with Unix.Unix_error _ -> ());
      Unix.rmdir root)
    (fun () ->
      assert (Container_runtime.local_selinux ~root () = None);
      List.iter
        (fun (text, expected) ->
          Out_channel.with_open_bin (Filename.concat root "enforce") (fun ch ->
              output_string ch text);
          assert (Container_runtime.local_selinux ~root () = expected))
        [ ("0\n", Some true); ("1\n", Some true); ("bad", None) ])

let () =
  let probes = ref 0 and calls = ref 0 in
  let resolve =
    Container_runtime.make_selinux_resolver
      ~probe:(fun () ->
        incr probes;
        None)
      ~run:(fun argv ->
        assert (argv = Podman_command.info);
        incr calls;
        Ok (result (Unix.WEXITED 125)))
      ()
  in
  assert (Result.is_error (resolve ()));
  assert (Result.is_error (resolve ()));
  assert (!probes = 1 && !calls = 1)

(* Failing to run Podman at all is explained in plain words. *)
let () =
  let fails operation message _ = Error { Process.operation; message } in
  let unavailable run =
    match Podman.available ~run () with
    | Error (Podman.Unavailable text) -> text
    | _ -> failwith "Expected Podman to be unavailable"
  in
  assert (
    unavailable (fails "launch" "podman: command not found")
    = "Podman was not found on PATH.");
  assert (
    unavailable (fails "launch" "podman: permission denied")
    = "Podman could not be started: permission denied");
  assert (
    unavailable (fails "capture" "No space left on device")
    = "capture: No space left on device");
  assert (
    match Podman.info ~run:(fails "launch" "podman: command not found") () with
    | Error (Podman.Unavailable text) ->
        String.starts_with ~prefix:"Podman was not found" text
    | _ -> false)
