module U = Deco.User_identity

let () =
  let calls = ref 0 in
  let provider () =
    incr calls;
    Ok U.{ uid = 1000; gid = 1001 }
  in
  let user : Config.Effective.user =
    {
      name = Some "dev";
      mode = Config.Keep_id;
      uid = Some Config.Host;
      gid = Some (Config.Id 42);
    }
  in
  (match U.resolve ~host_ids:provider user with
  | Ok (U.Keep_id { host; container; _ }) ->
      assert (host.uid = 1000 && container.uid = 1000 && container.gid = 42)
  | _ -> assert false);
  assert (!calls = 1);
  assert (
    U.resolve ~host_ids:provider
      { name = None; mode = Config.Image; uid = None; gid = None }
    = Ok U.Image);
  assert (!calls = 1);
  assert (
    Result.is_error (U.resolve ~host_ids:(fun () -> Error "lookup failed") user));
  assert (
    Result.is_error
      (U.resolve ~host_ids:(fun () -> Ok U.{ uid = -1; gid = 1 }) user));
  List.iter
    (fun user -> assert (Result.is_error (U.resolve ~host_ids:provider user)))
    [
      { user with name = None };
      { user with name = Some " " };
      { user with uid = None };
      { user with uid = Some (Config.Id (-1)) };
    ];
  List.iter
    (fun n ->
      let source =
        match
          Config.Decode.from_string
            (Printf.sprintf
               "project.name='demo'\nuser={mode='keep-id',name='dev',uid=%Ld}" n)
        with
        | Ok c -> c
        | Error _ -> assert false
      in
      assert (Result.is_error (Config.Validate.check source)))
    (List.filter (fun n -> n <= Int64.of_int max_int) [ -1L; 4294967295L ]);
  List.iter
    (fun text ->
      let source =
        match Config.Decode.from_string ("project.name='demo'\n" ^ text) with
        | Ok c -> c
        | Error _ -> assert false
      in
      assert (Result.is_error (Config.Validate.check source)))
    [ "user.uid=0"; "user={mode='image',gid='host'}" ]

let () =
  let user : Config.Effective.user =
    {
      name = Some "dev";
      mode = Config.Keep_id;
      uid = Some (Config.Id 0);
      gid = Some (Config.Id 0);
    }
  in
  assert (
    Result.is_ok
      (U.resolve ~host_ids:(fun () -> Ok U.{ uid = 0; gid = 0 }) user));
  if Int64.of_int max_int >= 4294967294L then
    let largest = Int64.to_int 4294967294L in
    assert (
      Result.is_ok
        (U.resolve
           ~host_ids:(fun () -> Ok U.{ uid = largest; gid = largest })
           { user with uid = Some (Config.Id largest); gid = Some Config.Host }))

let () =
  let valid = Config.Validate.valid_id in
  List.iter (fun n -> assert (not (valid n))) [ min_int; -1 ];
  List.iter (fun n -> assert (valid n)) [ 0; 1; 1000 ];
  List.iter
    (fun (n, expected) ->
      if n <= Int64.of_int max_int then
        assert (valid (Int64.to_int n) = expected))
    [ (4294967294L, true); (4294967295L, false) ];
  assert (valid max_int = (Int64.of_int max_int <= 4294967294L));
  let image : Config.Effective.user =
    {
      name = None;
      mode = Config.Image;
      uid = Some (Config.Id 1);
      gid = Some Config.Host;
    }
  in
  let source =
    match
      Config.Decode.from_string
        "project.name='demo'\nuser={mode='image',uid=1,gid='host'}"
    with
    | Ok c -> c
    | Error _ -> assert false
  in
  (match (U.resolve image, Config.Validate.check source) with
  | Error actual, Error expected -> assert (actual = expected)
  | _ -> failwith "Expected matching image-mode errors");
  let user =
    {
      image with
      mode = Config.Keep_id;
      name = Some "dev";
      uid = Some (Config.Id (-1));
    }
  in
  (match U.resolve ~host_ids:(fun () -> Ok U.{ uid = 1; gid = 1 }) user with
  | Error errors ->
      assert (
        List.exists
          (fun (e : Config.Diagnostic.t) ->
            e.message = "Container ID must be in 0-4294967294")
          errors)
  | Ok _ -> assert false);
  let source =
    {
      source with
      user =
        Some
          {
            name = Some "dev";
            mode = Some Config.Keep_id;
            uid = Some (Config.Id (-1));
            gid = None;
          };
    }
  in
  match Config.Validate.check source with
  | Error [ e ] -> assert (e.message = "Expected an ID in 0-4294967294")
  | _ -> assert false
