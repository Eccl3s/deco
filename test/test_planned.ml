let decode extra =
  Config.Decode.from_string_with_ignored ("project.name='example'\n" ^ extra)

let () =
  let config, paths =
    Result.get_ok
      (decode "container.namespaces.pid='host'\nnetwork.mode='pasta'")
  in
  assert ((Option.get config.Config.container).Config.name = None);
  assert (
    paths = [ [ "container"; "namespaces"; "pid" ]; [ "network"; "mode" ] ]);
  assert (
    Config.Decode.planned_settings
      "project.name='example'\n\
       container.namespaces.pid='host'\n\
       network.ports=[{host=8080,container=80}]\n\
       hooks.post_create='supported-not-listed'\n\
       actions={supported='not listed'}\n\
       container.name='supported-not-listed'"
    = [
        ([ "container"; "namespaces"; "pid" ], "\"host\"");
        ([ "network"; "ports[0]"; "container" ], "80");
        ([ "network"; "ports[0]"; "host" ], "8080");
      ]);
  assert (Config.Decode.planned_settings "not = [toml" = []);
  List.iter
    (fun extra -> assert (Result.is_error (decode extra)))
    [
      "network.mdoe='pasta'";
      "container.env_filse=['.env']";
      "hooks.post_strat='x'";
      "container.env_files=42";
      "container.env_files=[1]";
      "container.environment.TOKEN=42";
      "network.ports=[{host=12,typo=true}]";
      "mounts.volumes=[{target='/x',typo=true}]";
      "container.secrets=[{name='x',typo=true}]";
      "container.namespaces.typo='host'";
      "container.name=42";
      "unknown={}";
      "network.mode='pasta'\nnetwork.mode='host'";
    ];
  let _, paths =
    Result.get_ok
      (decode
         "network.ports=[{host=999999,container=1}]\n\
          mounts.volumes=[{source='/missing/path',target='/volume'}]\n\
          container.secrets=[{name='unavailable'}]\n\
          hooks.pre_stop='supported'")
  in
  assert (List.mem [ "network"; "ports[0]"; "host" ] paths);
  assert (List.mem [ "mounts"; "volumes[0]"; "source" ] paths);
  assert (
    Result.is_ok
      (decode
         "container.namespaces.pid='future-mode'\nnetwork.mode='future-mode'"))

(* Security options and the environment are supported settings, so they are no
   longer listed. *)
let () =
  assert (
    Config.Decode.planned_settings
      "project.name='example'\n\
       container.env_files=['.env']\n\
       container.environment.TOKEN='SECRET_VALUE'\n\
       container.privileged=true\n\
       container.devices=['/dev/fuse']\n\
       container.cap_add=['NET_ADMIN']\n\
       container.cap_drop=['ALL']\n\
       container.security_options=['label=disable']"
    = [])
