let write p s = Out_channel.with_open_bin p (fun c -> output_string c s)

let rec cleanup p =
  if (Unix.lstat p).st_kind = Unix.S_DIR then (
    Array.iter (fun n -> cleanup (Filename.concat p n)) (Sys.readdir p);
    Unix.rmdir p)
  else Unix.unlink p

let () =
  let binary = Unix.realpath Sys.argv.(1) in
  let temp = Filename.temp_file "deco-assemble-cli" "" in
  Unix.unlink temp;
  Unix.mkdir temp 0o700;
  Fun.protect
    ~finally:(fun () -> cleanup temp)
    (fun () ->
      let mkdir p = Unix.mkdir (temp ^ p) 0o700 in
      mkdir "/.deco";
      mkdir "/.deco/build";
      mkdir "/fake";
      mkdir "/child";
      let config = temp ^ "/.deco/config.toml" in
      write config "[project]\nname='example'\n";
      write (temp ^ "/.deco/build/Containerfile") "FROM scratch\n";
      let log = temp ^ "/calls" in
      let fake = temp ^ "/fake/podman" in
      let run ?(path = temp ^ "/fake") args expected =
        let out = temp ^ "/out" and err = temp ^ "/err" in
        let fd p =
          Unix.openfile p [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let o = fd out and e = fd err in
        let pid = Unix.fork () in
        if pid = 0 then (
          Unix.chdir (temp ^ "/child");
          Unix.putenv "PATH" path;
          Unix.putenv "XDG_STATE_HOME" (temp ^ "/state");
          Unix.putenv "DECO_TEST_LOG" log;
          Unix.dup2 o Unix.stdout;
          Unix.dup2 e Unix.stderr;
          Unix.close o;
          Unix.close e;
          Unix.execv binary (Array.of_list (binary :: args)));
        Unix.close o;
        Unix.close e;
        let _, status = Unix.waitpid [] pid in
        if status <> Unix.WEXITED expected then
          failwith (In_channel.with_open_bin err In_channel.input_all);
        ( In_channel.with_open_bin out In_channel.input_all,
          In_channel.with_open_bin err In_channel.input_all )
      in
      let contains s fragment =
        let rec loop i =
          i + String.length fragment <= String.length s
          && (String.sub s i (String.length fragment) = fragment || loop (i + 1))
        in
        loop 0
      in
      write fake
        {|#!/bin/sh
shift
case "$1 $2" in
  'version ') exit 0;;
  'info --format') printf '{}';;
  'image exists'|'container exists') exit 0;;
  'image inspect') printf '%s' '[{"Id":"iid","Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":"ROOT"},"Config":{"WorkingDir":"/"}}]';;
  'container inspect') printf '%s' '[{"Id":"cid","Image":"iid","State":{"Status":"running"},"Config":{"Labels":{"dev.deco.managed":"true","dev.deco.project":"example","dev.deco.project-root":"ROOT"},"WorkingDir":"/"},"HostConfig":{"UsernsMode":"","Init":true},"Mounts":[]}]';;
  'exec --interactive') shift; shift; [ "$1" = -- ] || exit 90; shift; [ "$1" = cid ] || exit 91; shift; exec "$@";;
  *) exit 92;;
esac
|};
      let script = In_channel.with_open_bin fake In_channel.input_all in
      let script =
        String.concat temp
          (String.split_on_char '\001'
             (let rec replace offset =
                if offset + 4 > String.length script then
                  String.sub script offset (String.length script - offset)
                else if String.sub script offset 4 = "ROOT" then
                  "\001" ^ replace (offset + 4)
                else String.make 1 script.[offset] ^ replace (offset + 1)
              in
              replace 0))
      in
      write fake script;
      Unix.chmod fake 0o700;
      let out, err =
        run
          [
            "exec";
            "--";
            "/bin/sh";
            "-c";
            "printf output; printf error >&2; exit 17";
          ]
          17
      in
      assert (out = "output" && err = "error");
      let out, err =
        run [ "exec"; "--"; "/bin/printf"; "%s"; "--project-dir" ] 0
      in
      assert (out = "--project-dir" && err = "");
      let out, err =
        run ~path:"/nonexistent" [ "exec"; "-d"; "--"; "echo"; "-h"; "" ] 0
      in
      assert (contains out "Exec preview" && err = ""))
