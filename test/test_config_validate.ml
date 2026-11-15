let decode text =
  match Config.Decode.from_string text with
  | Ok value -> value
  | Error _ -> failwith "Invalid test TOML"

let config suffix = decode ("project.name='demo'\n" ^ suffix)
let valid value = assert (Config.Validate.check value = Ok ())

let errors value =
  match Config.Validate.check value with
  | Error errors ->
      assert (errors <> []);
      errors
  | Ok () -> failwith "Expected validation error"

let () =
  valid (config "");
  List.iter
    (fun suffix -> valid (config suffix))
    [
      "user={mode='keep-id',name='dev',uid=-5}";
      "container={shell='sh',workdir='/'}";
      "container={shell='/bin/sh',workdir='/workspace//src/'}";
      "mounts.workspace.target='/workspace'";
      "build.args={A='',_A1='$HOME',user_uid='literal'}";
      "user={mode='image'}";
    ];
  List.iter
    (fun suffix -> ignore (errors (config suffix)))
    [
      "container.name='-bad'";
      "container.workdir='relative'";
      "container.workdir='/a/./b'";
      "container.workdir='/a/../b'";
      "container.shell='  '";
      "container.shell='bin/sh'";
      "mounts.workspace.target=''";
      "build.args.'bad.key'=''";
      "build.args.USER_NAME=''";
      "build.args.USER_UID=''";
      "build.args.USER_GID=''";
      "user.mode='keep-id'";
      "user={mode='keep-id',name='  '}";
      "user.name='dev'";
      "user={mode='image',name=''}";
    ];
  List.iter
    (fun name -> ignore (errors (decode ("project.name='" ^ name ^ "'"))))
    [ ""; "  "; "-bad"; "bad!"; "é"; String.make 129 'a' ];
  List.iter
    (fun name ->
      valid (decode ("project.name='" ^ name ^ "'\ncontainer.name='short'")))
    [ "a"; "0"; "A.b_c-d"; String.make 128 'a' ];
  let c = config "user={}\ncontainer={}\nmounts={}" in
  let before = Marshal.to_string c [] in
  valid c;
  assert (Marshal.to_string c [] = before);
  let es =
    errors
      (config
         "container={name='!',shell=''}\n\
          user.mode='keep-id'\n\
          build.args.'a.b'=''")
  in
  assert (List.length es = 4);
  let paths = List.map (fun (e : Config.Validate.error) -> e.path) es in
  assert (
    paths
    = [
        [ "build"; "args"; "a.b" ];
        [ "container"; "name" ];
        [ "container"; "shell" ];
        [ "user"; "name" ];
      ]);
  assert (
    String.starts_with ~prefix:"build.args.\"a.b\":"
      (Config.Validate.error_to_string (List.hd es)));
  assert (
    Config.Validate.error_to_string { path = []; message = "problem" }
    = "problem")

let () =
  ignore (errors (config "container.shell='/bin/../sh'"));
  ignore (errors (config "build.args.''='x'"));
  (* Image reference grammar and IDs in image mode are intentionally deferred. *)
  valid (config "image={tag=''}");
  valid (config "user={mode='image',uid=1000}");
  (* Lexical paths need only be absolute and exclude dot components. *)
  valid (config "container={shell='/',workdir='/a//b/'}")

let () =
  let named n suffix =
    decode ("project.name='" ^ String.make n 'a' ^ "'\n" ^ suffix)
  in
  List.iter
    (fun suffix ->
      valid (named 114 suffix);
      List.iter
        (fun n ->
          match errors (named n suffix) with
          | [ e ] ->
              assert (e.path = [ "container"; "name" ]);
              assert (
                String.starts_with
                  ~prefix:"Derived container name exceeds 128 characters"
                  e.message)
          | _ -> failwith "Expected derived-name error")
        [ 115; 128 ])
    [ ""; "container={}"; "container.shell='sh'" ];
  valid (named 128 "container.name='short'");
  ignore (errors (named 128 "container.name='!'"));
  match errors (decode "project.name='-invalid'") with
  | [ e ] -> assert (e.path = [ "project"; "name" ])
  | _ -> failwith "Unexpected cascading diagnostic"
