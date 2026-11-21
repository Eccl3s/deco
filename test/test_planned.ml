let decode extra =
  Config.Decode.from_string_with_ignored ("project.name='example'\n" ^ extra)

let () =
  let config, paths =
    Result.get_ok
      (decode
         "container.cap_drop=['ALL']\n\
          network.mode='pasta'\n\
          actions.test='DO_NOT_PRINT'\n\
          container.environment.TOKEN='SECRET_VALUE'")
  in
  assert ((Option.get config.Config.container).Config.name = None);
  assert (
    paths
    = [
        [ "actions"; "test" ];
        [ "container"; "cap_drop" ];
        [ "container"; "environment"; "TOKEN" ];
        [ "network"; "mode" ];
      ]);
  assert (
    Config.Decode.planned_settings
      "project.name='example'\n\
       container.cap_drop=['ALL']\n\
       container.privileged=true\n\
       network.ports=[{host=8080,container=80}]\n\
       hooks.post_create=\"say \\\"hi\\\"\\nthen\\t\\\\ done\"\n\
       actions={}\n\
       container.environment.TOKEN='SECRET_VALUE'\n\
       container.name='supported-not-listed'"
    = [
        ([ "actions" ], Some "{}");
        ([ "container"; "cap_drop" ], Some "[\"ALL\"]");
        ([ "container"; "environment"; "TOKEN" ], None);
        ([ "container"; "privileged" ], Some "true");
        ([ "hooks"; "post_create" ], Some {|"say \"hi\"\nthen\t\\ done"|});
        ([ "network"; "ports[0]"; "container" ], Some "80");
        ([ "network"; "ports[0]"; "host" ], Some "8080");
      ]);
  assert (Config.Decode.planned_settings "not = [toml" = []);
  List.iter
    (fun extra -> assert (Result.is_error (decode extra)))
    [
      "network.mdoe='pasta'";
      "container.cap_dorp=['ALL']";
      "hooks.post_strat='x'";
      "container.cap_drop=42";
      "container.cap_drop=[1]";
      "container.environment.TOKEN=42";
      "network.ports=[{host=12,typo=true}]";
      "mounts.volumes=[{target='/x',typo=true}]";
      "container.secrets=[{name='x',typo=true}]";
      "container.namespaces.typo='host'";
      "container.name=42";
      "actions={test=42}";
      "unknown={}";
      "network.mode='pasta'\nnetwork.mode='host'";
    ];
  let _, paths =
    Result.get_ok
      (decode
         "network.ports=[{host=999999,container=1}]\n\
          mounts.volumes=[{source='/missing/path',target='/volume'}]\n\
          container.devices=['/missing/device']\n\
          container.secrets=[{name='unavailable'}]\n\
          hooks.pre_stop='never run'")
  in
  assert (List.mem [ "network"; "ports[0]"; "host" ] paths);
  assert (List.mem [ "mounts"; "volumes[0]"; "source" ] paths);
  assert (
    Result.is_ok
      (decode
         "container.cap_drop=['FUTURE_CAPABILITY']\nnetwork.mode='future-mode'"))
