open Deco

let () =
  let created =
    1794388442.
    (* 2026-11-11T09:14:02Z *)
  in
  let now = created +. (9. *. 86400.) in
  let full : Info.report =
    {
      project =
        {
          name = "example";
          description = Some "Demo";
          root = "/project";
          config = "/project/.deco/config.toml";
        };
      trust =
        Some
          {
            state = "changed";
            digest = "blake2b-256:abc";
            trusted_at = Some created;
            changed =
              [
                ("config.toml", "modified"); ("build/Containerfile", "removed");
              ];
          };
      podman = { available = true; version = Some "5.7.0" };
      image =
        {
          name = "example-dev-image";
          tag = "latest";
          id = Some "iid";
          exists = Some true;
          created = Some created;
          owned = Some true;
        };
      container =
        {
          name = "example-dev-container";
          id = Some "cid";
          exists = Some true;
          state = Some "stopped";
          podman_state = Some "exited";
          created = Some (created +. 3600.);
          owned = Some true;
          compatible = Some false;
          incompatibilities =
            [ "Container init is disabled"; "Working directory differs" ];
        };
      runtime =
        { user_mode = "keep-id"; workdir = Some "/workspace"; shell = "bash" };
      security =
        {
          privileged = true;
          devices = [ "/dev/fuse"; "/dev/a:/dev/b:rw" ];
          cap_add = [ "SYS_ADMIN" ];
          cap_drop = [ "ALL" ];
          security_options = [ "label=disable\x1b[2J" ];
        };
      environment =
        {
          variables = [ "NODE_ENV"; "TOKEN\x1b[2J" ];
          env_files = [ "/project/.env"; "/host/shared.env" ];
        };
      mounts =
        [
          {
            source = "/project";
            target = "/workspace";
            kind = "bind";
            readonly = false;
            relabel = "private";
          };
        ];
      dns = [ "1.1.1.1" ];
      ports =
        [
          { host = 8080; container = 80; protocol = "tcp"; bind = "127.0.0.1" };
        ];
      hooks = [ "post_start" ];
      actions = [ "test" ];
    }
  in
  let check name actual expected =
    if actual <> expected then
      failwith (Printf.sprintf "%s:\n%s\nexpected:\n%s" name actual expected)
  in
  check "full"
    (Info.render_human ~now ~ignored:[] full)
    {|Project
  Name:        example
  Description: Demo
  Root:        /project
  Config:      /project/.deco/config.toml

Trust
  State:       changed
  Digest:      blake2b-256:abc
  Approved:    2026-11-11 09:14 UTC (9 days ago)
    - modified config.toml
    - removed build/Containerfile

Podman
  Available:   yes
  Version:     5.7.0

Image
  Name:        example-dev-image
  Tag:         latest
  ID:          iid
  Exists:      yes
  Created:     2026-11-11 09:14 UTC (9 days ago)
  Owned:       yes

Container
  Name:        example-dev-container
  ID:          cid
  Exists:      yes
  State:       stopped (exited)
  Created:     2026-11-11 10:14 UTC (8 days ago)
  Owned:       yes
  Compatible:  no
    - Container init is disabled
    - Working directory differs

Runtime
  User mode:   keep-id
  Workdir:     /workspace
  Shell:       bash

Security
  Privileged:  yes
  Devices:     /dev/fuse, /dev/a:/dev/b:rw
  Cap add:     SYS_ADMIN
  Cap drop:    ALL
  Options:     label=disable\x1b[2J

Environment
  Variables:   NODE_ENV, TOKEN\x1b[2J
  Env files:   /project/.env, /host/shared.env

Mounts
  /project -> /workspace (bind, read-write, relabel private)

DNS
  1.1.1.1

Ports
  127.0.0.1:8080 -> 80/tcp

Hooks
  post_start

Actions
  test
|};
  (* Podman unavailable: unknown values are "-", empty collections "none",
     and ignored settings close the report. *)
  let sparse : Info.report =
    {
      project = { full.project with description = None };
      trust = None;
      podman = { available = false; version = None };
      image =
        {
          full.image with
          id = None;
          exists = None;
          created = None;
          owned = None;
        };
      container =
        {
          full.container with
          id = None;
          exists = None;
          state = None;
          podman_state = None;
          created = None;
          owned = None;
          compatible = None;
          incompatibilities = [];
        };
      runtime = { user_mode = "image"; workdir = None; shell = "sh" };
      security =
        {
          privileged = false;
          devices = [];
          cap_add = [];
          cap_drop = [];
          security_options = [];
        };
      environment = { variables = []; env_files = [] };
      mounts = [];
      dns = [];
      ports = [];
      hooks = [];
      actions = [];
    }
  in
  check "sparse"
    (Info.render_human ~now
       ~ignored:[ [ "hooks"; "post_start" ]; [ "actions" ] ]
       sparse)
    {|Project
  Name:        example
  Description: -
  Root:        /project
  Config:      /project/.deco/config.toml

Trust
  State:       -
  Digest:      -
  Approved:    -

Podman
  Available:   no
  Version:     -

Image
  Name:        example-dev-image
  Tag:         latest
  ID:          -
  Exists:      -
  Created:     -
  Owned:       -

Container
  Name:        example-dev-container
  ID:          -
  Exists:      -
  State:       -
  Created:     -
  Owned:       -
  Compatible:  -

Runtime
  User mode:   image
  Workdir:     -
  Shell:       sh

Security
  Privileged:  no
  Devices:     none
  Cap add:     none
  Cap drop:    none
  Options:     none

Environment
  Variables:   none
  Env files:   none

Mounts
  none

DNS
  none

Ports
  none

Hooks
  none

Actions
  none

Ignored planned settings (not applied yet):
  hooks.post_start
  actions
|};
  (* A state Podman reports identically is shown once. *)
  let running =
    {
      full with
      container =
        {
          full.container with
          state = Some "running";
          podman_state = Some "running";
        };
    }
  in
  let out = Info.render_human ~now ~ignored:[] running in
  assert (List.mem "  State:       running" (String.split_on_char '\n' out));
  (* Reported values cannot inject terminal sequences. *)
  let hostile : Info.report =
    {
      full with
      project =
        { full.project with description = Some "a\027[31mb"; root = "/p\nq" };
      container =
        { full.container with incompatibilities = [ "bad\xe2\x80\xaeone" ] };
      mounts = [ { (List.hd full.mounts) with source = "/s\tt" } ];
      trust =
        Option.map
          (fun (t : Info.trust) ->
            { t with changed = [ ("evil\027[2J", "added") ] })
          full.trust;
    }
  in
  let out = Info.render_human ~now ~ignored:[ [ "x\027y" ] ] hostile in
  assert (not (String.contains out '\027'));
  let lines = String.split_on_char '\n' out in
  List.iter
    (fun expected ->
      if not (List.mem expected lines) then failwith (expected ^ "\n" ^ out))
    [
      "  Description: a\\x1b[31mb";
      "  Root:        /p\\x0aq";
      "    - bad\\u{202e}one";
      "  /s\\x09t -> /workspace (bind, read-write, relabel private)";
      "  x\\x1by";
      "    - added evil\\x1b[2J";
    ]
