# Deco TOML v1 Specification

## 1. Status and terminology

This document defines the normative v1 configuration format for Deco. A
conforming implementation must implement the behavior described here.

The key words **must**, **must not**, **required**, **should**, and **may** are
to be interpreted as requirements.

The canonical configuration path is `.deco/config.toml`, relative to the project
root. The project root is the directory containing `.deco/`. A `config.toml`
stored elsewhere, including directly in the project root, is not discovered
automatically.

Deco supports Podman and Docker. Configuration has the same observable
behavior with either engine. If the selected engine cannot implement a
configured feature, Deco must report a validation error instead of silently
changing or omitting the feature, except for Podman secret references as
described under `[[container.secrets]]`.

## 2. Parsing and validation

- The file must be valid TOML.
- Key names are case-sensitive.
- Unknown tables and keys are errors. The error must include the full TOML key
  path.
- A required string must contain at least one non-whitespace character.
- Relative host paths are resolved from the project root, not from `.deco/`.
- A leading `~` in a host path expands to the current host user's home
  directory. Other tilde forms, such as `~other-user`, are invalid.
- Environment variables are not expanded in configuration values.
- Container paths must be absolute POSIX paths and must not contain `.` or
  `..` path components.
- Validation must happen before Deco builds, creates, starts, stops, or removes
  a container.

The complete top-level schema is:

```toml
[project]
[image]
[build]
[build.args]
[user]
[container]
[container.namespaces]
[[container.secrets]]
[network]
[[network.ports]]
[mounts.workspace]
[[mounts.volumes]]
[hooks]
[actions]
```

`project` is required. All other top-level tables are optional unless a field
rule below makes them necessary.

## 3. Project metadata

### `[project]`

Describes the Deco project.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `name` | string | yes | none | Stable project identifier used to derive engine resource names. |
| `description` | string | no | none | Human-readable project description shown by informational commands. |

`project.name` must be a valid Podman and Docker name component: 1-128
characters containing only ASCII letters, digits, `.`, `_`, or `-`; it must
start with an ASCII letter or digit.

Example:

```toml
[project]
name = "my-project"
description = "Development environment for my project"
```

## 4. Image and build

### `[image]`

Controls the name assigned to the locally built image.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `name` | string | no | `<project.name>-dev-image` | Local image repository name. |
| `tag` | string | no | `"latest"` | Local image tag. |

Both values must be valid for Podman and Docker. `image.name` must not contain
a tag or digest; `image.tag` supplies the tag separately. Deco refers to the
result as `<image.name>:<image.tag>`.

Example:

```toml
[image]
name = "my-project-dev-image"
tag = "latest"
```

### `[build]`

Controls the container image build. Omitting the table is equivalent to using
all defaults.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `context` | string | no | `".deco/build"` | Host directory sent to the image build as its context. |
| `containerfile` | string | no | `"Containerfile"` | Containerfile path. |
| `target` | string | no | none | Named multi-stage build target. |
| `pull` | boolean | no | `false` | Request a newer version of referenced base images. |
| `no_cache` | boolean | no | `false` | Disable reuse of cached build layers. |

`build.context` is resolved as a host path and must exist as a directory.
`build.containerfile` is resolved relative to the resolved build context when
it is relative. An absolute containerfile path is permitted only when it is
inside the build context. It must exist as a regular file.

`build.target`, when set, must name a stage present in the containerfile. An
unknown target is a build error.

Example:

```toml
[build]
context = ".deco/build"
containerfile = "Containerfile"
target = "dev"
pull = true
no_cache = false
```

### `[build.args]`

Defines build arguments passed to the image build. Each key is an argument
name and each value must be a string. The table is optional and has no
entries by default.

Argument names must match `[A-Za-z_][A-Za-z0-9_]*`. Values are passed
literally; Deco does not perform shell or environment expansion. Secrets must
not be placed in build arguments because container engines may retain them in
image metadata or build history.

`USER_NAME`, `USER_UID`, and `USER_GID` are reserved for Deco's `[user]`
configuration and must not be set in `[build.args]`.

Example:

```toml
[build.args]
NODE_VERSION = "22"
```

## 5. Container user and runtime

### `[user]`

Selects the identity used for hooks, actions, `deco exec`, and `deco shell`.
If the table is omitted, `mode` defaults to `"image"`.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `name` | string | for `keep-id` and `host-user` | none | User account name created by the generated image and selected at runtime. |
| `mode` | string enum | no | `"image"` | User identity strategy: `keep-id`, `host-user`, `root`, or `image`. |
| `uid` | string `"host"` or integer | for `keep-id` and `host-user` | `"host"` | UID used for generated `USER_UID` build argument and runtime identity. |
| `gid` | string `"host"` or integer | for `keep-id` and `host-user` | `"host"` | GID used for generated `USER_GID` build argument and runtime identity. |

Mode behavior:

- `keep-id`: `user.name` is required. The account must exist in the image.
  Deco builds the image with `USER_NAME`, `USER_UID`, and `USER_GID`, then
  creates Podman containers with `--userns=keep-id:uid=<uid>,gid=<gid>` and
  `--user <name>`.
- `host-user`: `user.name` is required. Deco builds the image with
  `USER_NAME`, `USER_UID`, and `USER_GID`, then creates containers with
  `--user <uid>:<gid>`. This mode is the Docker-compatible host identity
  strategy.
- `root`: processes run with UID and GID `0`. `user.name` must not be set.
- `image`: processes run as the user configured by the image. If the image
  does not configure a user, this is root. `user.name` must not be set.

When `uid` or `gid` is `"host"`, Deco resolves the value from the current
Unix process user before building or creating containers. On platforms where
host UID/GID resolution is unavailable, commands that require `"host"` must
fail with a configuration error.

For `keep-id`, Deco must fail container creation when the selected engine
cannot map the requested UID and GID without changing the specified behavior.

Example:

```toml
[user]
name = "dev"
mode = "keep-id"
uid = "host"
gid = "host"
```

### `[container]`

Controls the created development container.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `name` | string | no | `<project.name>-dev-container` | Container name. |
| `workdir` | string | no | workspace target or image default | Working directory for hooks, actions, exec, and shell commands. |
| `shell` | string | no | `"sh"` | Executable used to evaluate configured commands. |
| `env_files` | array of strings | no | `[]` | Host env files passed to container creation. |
| `privileged` | boolean | no | `false` | Run the container in privileged mode. |
| `devices` | array of strings | no | `[]` | Device mappings passed to container creation. |
| `cap_add` | array of strings | no | `[]` | Linux capabilities to add. |
| `cap_drop` | array of strings | no | `[]` | Linux capabilities to drop. |
| `security_options` | array of strings | no | `[]` | Security options passed to container creation. |

`container.name` must satisfy the same naming rules as `project.name`.

`container.workdir` must be an absolute container path. When omitted, it defaults to
`mounts.workspace.target` if a workspace is configured; otherwise Deco uses
the working directory configured by the image.

`container.shell` must identify an executable available in the image. A bare name is
resolved using the container's `PATH`; a value containing `/` must be an
absolute container path. Configured hooks and actions are invoked as:

```text
<container.shell> -lc <command>
```

Deco containers persist until removed with the Deco removal workflow. There
is no automatic removal option in v1.

Advanced create-time options map directly to supported Podman and Docker
container-create flags:

| Key | Engine flag |
| --- | --- |
| `privileged` | `--privileged` |
| `env_files` | repeated `--env-file` |
| `devices` | repeated `--device` |
| `cap_add` | repeated `--cap-add` |
| `cap_drop` | repeated `--cap-drop` |
| `security_options` | repeated `--security-opt` |

Each `env_files` entry is resolved as a host path from the project root and
must exist as a regular file. Env file contents are parsed by the selected
container engine.

Each `devices` entry must be one of `HOST_PATH`, `HOST_PATH:CONTAINER_PATH`,
or `HOST_PATH:CONTAINER_PATH:PERMISSIONS`. `HOST_PATH` must be absolute.
`CONTAINER_PATH`, when present, must be an absolute container path.
`PERMISSIONS`, when present, may contain only `r`, `w`, and `m` with no
duplicates. Capability names must be non-empty and contain only ASCII
letters, digits, `_`, or `-`. Security options must be non-empty.

### `[container.environment]`

Defines environment variables passed to container creation. The table is
optional and empty by default. Each key must match `[A-Za-z_][A-Za-z0-9_]*`.
Values must be strings and are passed literally; Deco does not perform shell
or environment expansion.

### `[[container.secrets]]`

References Podman-managed secrets to attach at container creation. The array
is optional and empty by default. Deco never stores, creates, updates,
removes, inspects, or prints secret contents; users manage secret values with
`podman secret`.

When Podman is selected, each entry maps to a repeated `--secret` create flag.
When Docker is selected, Deco validates the configuration but omits these
flags, writes a warning before starting the container, and continues.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `name` | string | yes | none | Existing Podman secret name. |
| `type` | string enum | no | `"mount"` | Exposure mode: `mount` or `env`. |
| `target` | string | no | Podman default | Mount path/name or environment variable name. |
| `uid` | integer | no | Podman default | Mount-secret UID; valid only for `type = "mount"`. |
| `gid` | integer | no | Podman default | Mount-secret GID; valid only for `type = "mount"`. |
| `mode` | string | no | Podman default | Mount-secret octal mode; valid only for `type = "mount"`. |

`name` must be non-empty and must not contain whitespace, `,`, or `=`.
For `type = "env"`, `target` must match `[A-Za-z_][A-Za-z0-9_]*`, and `uid`,
`gid`, and `mode` must not be set. For `type = "mount"`, an absolute `target`
must be a valid container path; a relative `target` is passed to Podman as a
secret target name and must not contain whitespace, `,`, or `=`.
`mode` must be 3 or 4 octal digits.

Example:

```toml
[[container.secrets]]
name = "npmrc"
target = "/home/dev/.npmrc"
uid = 1000
gid = 1000
mode = "0400"

[[container.secrets]]
name = "github-token"
type = "env"
target = "GITHUB_TOKEN"
```

### `[container.namespaces]`

Configures runtime namespace modes during container creation. The table is
optional and all keys default to unset.

| Key | Type | Required | Default | Engine flag |
| --- | --- | --- | --- | --- |
| `pid` | string | no | none | `--pid` |
| `ipc` | string | no | none | `--ipc` |
| `uts` | string | no | none | `--uts` |
| `cgroup` | string | no | none | `--cgroupns` |
| `user` | string | no | none | `--userns` |

Namespace values must be non-empty and are passed literally to the selected
engine. `container.namespaces.user` must not be set when `user.mode` is
`keep-id`, because Deco uses the user namespace to implement `keep-id`.

Example:

```toml
[container]
name = "my-project-dev-container"
workdir = "/workspace"
shell = "bash"
env_files = [".env"]
privileged = false
devices = ["/dev/fuse:/dev/fuse:rwm"]
cap_add = ["NET_ADMIN"]
cap_drop = ["MKNOD"]
security_options = ["label=disable"]

[container.environment]
NODE_ENV = "development"

[container.namespaces]
pid = "host"
```

## 6. Networking

### `[network]`

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `dns` | array of strings | no | `[]` | DNS server addresses passed to the engine as repeated `--dns` flags. |
| `mode` | string enum | no | `"bridge"` | Container network mode: `bridge`, `host`, or `pasta`. |

- `bridge` gives the container an engine-managed network namespace and permits
  entries in `network.ports`.
- `host` shares the host network namespace. `network.ports` must be absent or
  empty because port publishing has no meaning in this mode.
- `pasta` uses Podman's pasta networking and permits entries in
  `network.ports` where the selected Podman version supports publishing.
  `pasta` is Podman-only; when Docker is selected, Deco must fail instead of
  falling back to bridge networking.
- `dns` entries must be literal IPv4 or IPv6 addresses. Hostnames are not
  accepted. Entry order is preserved.

### `[[network.ports]]`

Each entry publishes one container port. The array is optional and empty by
default.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `host` | integer | yes | none | Host port to listen on. |
| `container` | integer | yes | none | Port inside the container. |
| `protocol` | string enum | no | `"tcp"` | Transport protocol: `tcp` or `udp`. |
| `bind` | string | no | `"127.0.0.1"` | Host IPv4 or IPv6 address on which to listen. |

Port numbers must be in the range 1-65535. `bind` must be a literal IP
address; hostnames are not accepted. Two entries must not use the same
`bind`, `host`, and `protocol` tuple. The same container port may be published
more than once when the host tuple differs.

Example:

```toml
[network]
mode = "bridge"
dns = ["1.1.1.1", "2606:4700:4700::1111"]

[[network.ports]]
host = 3000
container = 3000
protocol = "tcp"
bind = "127.0.0.1"
```

## 7. Mounts

### `[mounts.workspace]`

Mounts the project workspace into the container. The table is optional.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `source` | string | no | `"."` | Existing host directory to mount. |
| `target` | string | yes | none | Absolute container directory receiving the mount. |
| `relabel` | string enum | no | `"none"` | SELinux relabel policy: `shared`, `private`, or `none`. |

The workspace is a read-write bind mount. `source` is resolved as a host path
and must exist as a directory. `target` must not conflict with another mount
target.

### `[[mounts.volumes]]`

Defines additional mounts. The array is optional and empty by default.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `source` | string | per type | none | Bind host path, named volume name, or image reference. |
| `target` | string | yes | none | Absolute container path receiving the mount. |
| `type` | string enum | no | `"bind"` | Mount type: `bind`, `volume`, `image`, `tmpfs`, or `devpts`. |
| `readonly` | boolean | no | type-specific | Mount without container write access. Defaults to `true` for `image` and `false` otherwise. |
| `relabel` | string enum | no | `"none"` | SELinux relabel policy for bind mounts: `shared`, `private`, or `none`. |
| `subpath` | string | no | none | Absolute path inside the source image for `image` mounts. |
| `size` | integer | no | engine default | tmpfs size in bytes. |
| `mode` | string | no | engine default | Octal mode for `tmpfs` or `devpts`. |
| `uid` | integer | no | engine default | Numeric owner UID for `devpts`. |
| `gid` | integer | no | engine default | Numeric owner GID for `devpts`. |
| `max` | integer | no | engine default | Maximum pseudo-terminal count for `devpts`. |
| `chown` | boolean | no | `false` | For `tmpfs`, pass the engine `U` option to chown the mount to the container user. |

Mount targets must be unique across the workspace and all volume entries.

Per-type rules:

| Type | Support | Required keys | Optional keys | Rejected keys |
| --- | --- | --- | --- | --- |
| `bind` | Docker, Podman | `source`, `target` | `readonly`, `relabel` | `subpath`, `size`, `mode`, `uid`, `gid`, `max`, `chown` |
| `volume` | Docker, Podman | `source`, `target` | `readonly` | `relabel`, `subpath`, `size`, `mode`, `uid`, `gid`, `max`, `chown` |
| `image` | Podman only | `source`, `target` | `readonly`, `subpath` | `relabel`, `size`, `mode`, `uid`, `gid`, `max`, `chown` |
| `tmpfs` | Docker, Podman | `target` | `readonly`, `size`, `mode`, `chown` | `source`, `relabel`, `subpath`, `uid`, `gid`, `max` |
| `devpts` | Podman only | `target` | `uid`, `gid`, `mode`, `max` | `source`, `readonly`, `relabel`, `subpath`, `size`, `chown` |

For a bind mount, `source` must exist and may be either a file or directory.
For an image mount, `subpath` must be absolute and must not contain `.` or
`..` path components. The image mount `source` must already exist locally
unless it is the configured project image and Deco is about to build it during
the same operation. Deco does not pull image mount sources automatically.
`mode` values must contain one to four octal digits. Mount option values must
not contain commas.

Named `volume` mounts are first-class Deco resources. Deco creates missing
configured named volumes with the same ownership labels used for images and
containers. Existing configured named volumes must either be absent or carry
matching Deco ownership labels; otherwise Deco exits with a resource conflict
before mutating engine resources. `deco remove` removes configured owned named
volumes by default, `deco remove --keep-volumes` preserves them, and
`deco refresh --volumes` removes and recreates them before creating the
replacement container.

When Docker is selected, Podman-only mount types must fail validation before
Deco builds, creates, starts, stops, or removes engine resources.

Relabel modes map to container-engine behavior as follows:

| Value | Behavior |
| --- | --- |
| `shared` | Relabel content for sharing between multiple containers; equivalent to `:z`. |
| `private` | Relabel content for private use by this container; equivalent to `:Z`. |
| `none` | Do not request SELinux relabeling. |

An engine or host that does not support a requested relabel mode must produce
a validation error.

Example:

```toml
[mounts.workspace]
source = "."
target = "/workspace"
relabel = "shared"

[[mounts.volumes]]
source = "~/.ssh"
target = "/home/dev/.ssh"
type = "bind"
readonly = true
relabel = "none"

[[mounts.volumes]]
source = "cargo-cache"
target = "/home/dev/.cargo"
type = "volume"

[[mounts.volumes]]
target = "/tmp/build"
type = "tmpfs"
size = 268435456
mode = "1777"
chown = true
```

## 8. Lifecycle hooks

### `[hooks]`

All hook keys are optional strings. Commands run inside the container as the
selected user, in `container.workdir`, through `container.shell`. A nonzero exit status
fails the current Deco operation immediately and is returned to the caller.

| Key | Timing |
| --- | --- |
| `post_create` | Once after each successful container creation. It runs before the first `post_start`. |
| `post_start` | After every successful container start, including the initial start. |
| `pre_enter` | Immediately before each interactive `deco shell` entry. |
| `pre_stop` | Before Deco explicitly stops or removes a running container. |

Lifecycle ordering for initial assembly is:

1. Build or select the image.
2. Create the container.
3. Start the container.
4. Run `post_create`.
5. Run `post_start`.

On later starts, Deco runs only `post_start`. Recreating the container causes
`post_create` to run again because it is a new container.

`pre_stop` is not run when the container has already stopped, exits outside
Deco, or cannot execute commands. A failed `pre_stop` prevents the requested
stop or removal.

Example:

```toml
[hooks]
post_create = "npm install"
post_start = "echo Ready"
pre_enter = "echo Entering dev shell"
pre_stop = "echo Stopping"
```

## 9. Actions

### `[actions]`

Defines named commands invoked by `deco run <action>`. Each key is an action
name and each value must be a non-empty command string. The table is optional
and empty by default.

Action names must match `[A-Za-z][A-Za-z0-9_-]*`. They are case-sensitive.
Commands run inside the running container as the selected user, in
`container.workdir`, through `container.shell`. A nonzero exit status is returned by Deco.
Deco must report an error when the requested action does not exist.

Example:

```toml
[actions]
setup = "npm install"
dev = "npm run dev"
test = "npm test"
```

## 10. Complete example

```toml
[project]
name = "my-project"
description = "Example deco toml file"

[image]
name = "my-project-dev-image"
tag = "latest"

[build]
context = ".deco/build"
containerfile = "Containerfile"
target = "dev"
pull = true
no_cache = false

[build.args]
NODE_VERSION = "22"

[user]
name = "dev"
mode = "keep-id"

[container]
name = "my-project-dev-container"
workdir = "/workspace"
shell = "bash"
env_files = [".env"]
privileged = false
devices = ["/dev/fuse:/dev/fuse:rwm"]
cap_add = ["NET_ADMIN"]
cap_drop = ["MKNOD"]
security_options = ["label=disable"]

[container.environment]
NODE_ENV = "development"

[container.namespaces]
pid = "host"

[network]
mode = "bridge"

[[network.ports]]
host = 3000
container = 3000
protocol = "tcp"
bind = "127.0.0.1"

[mounts.workspace]
source = "."
target = "/workspace"
relabel = "shared"

[[mounts.volumes]]
source = "~/.ssh"
target = "/home/dev/.ssh"
type = "bind"
readonly = true
relabel = "none"

[hooks]
post_create = "npm install"
post_start = "echo Ready"
pre_enter = "echo Entering dev shell"
pre_stop = "echo Stopping"

[actions]
setup = "npm install"
dev = "npm run dev"
test = "npm test"
```
