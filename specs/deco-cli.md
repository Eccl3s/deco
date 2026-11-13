# Deco CLI v1 Specification

## 1. Status and terminology

This document defines the v1 command-line interface for deco.

Deco is a Podman-only tool: Podman is the only supported container engine.

The key words **must**, **must not**, **required**, **should**, and **may** are
to be interpreted as requirements.

Configuration behavior is defined by
[`deco-config.md`](./deco-config.md). When this document and the config
specification discuss the same lifecycle operation, the requirements in both
documents apply.

Command names, option names, template names, and action names are
case-sensitive.

## 2. Command summary

```text
deco [GLOBAL OPTIONS] <COMMAND>

Commands:
  validate                    Validate the project configuration
  init [PATH]                 Initialize Deco files
  assemble                    Build, create, and start the environment
  refresh                     Rebuild the image and recreate the container
  remove                      Remove the environment
  rm                          Alias for remove
  start                       Start an existing container
  stop                        Stop a running container
  info                        Show project and environment information
  list                        List Deco-managed containers
  exec -- <COMMAND...>        Execute a command in the container
  shell                       Enter the configured interactive shell
  actions                     List configured actions
  run <ACTION>                Run a configured action
  completion bash             Generate a Bash completion script
```

## 3. Global behavior

### Global options

| Option | Description |
| --- | --- |
| `-p, --project <NAME>` | Select an assembled project by its configured name. |
| `--project-dir <PATH>` | Select a project directory explicitly. |
| `--format <human\|json>` | Select output format for supported informational commands. |
| `-v, --verbose` | Write additional diagnostics to stderr. Repeat occurrences may increase detail. |
| `-h, --help` | Print help for Deco or the selected command, then exit. |
| `-V, --version` | Print the Deco version, then exit. |

Global options may appear before or after the command unless they occur after
the `--` separator used by `deco exec`.

`--project` and `--project-dir` are mutually exclusive and are accepted by commands that operate on one project:
`validate`, `assemble`, `refresh`, `remove`, `start`, `stop`, `info`, `exec`,
`shell`, `actions`, and `run`. It is not accepted by `init`, `list`,
or `completion`. `init` uses its positional `PATH` instead.

Every command that creates, starts, stops, or removes Podman resources accepts
`-d, --dry-run` to print the planned operations without mutating anything;
see section 7.

`--keep-image` has one meaning wherever it is accepted: the configured image
is left untouched. On `remove` it is not deleted; on `refresh` it is not
rebuilt.

### Project discovery

When a project command is invoked:

1. If `--project-dir` is supplied, Deco resolves that path to an absolute
   directory and requires `<PATH>/.deco/config.toml` to exist.
2. If `--project` is supplied, Deco finds managed
   containers with a matching `dev.deco.project` label, and uses their
   `dev.deco.project-root` labels. The root must canonicalize to a directory
   containing `.deco/config.toml` whose `project.name` matches `<NAME>`. A
   missing or ambiguous match fails with exit code `2`; use `--project-dir`
   to select an explicit root. If Podman is unavailable during this lookup,
   the command fails with exit code `3`.
3. Otherwise, Deco starts at the current directory and searches it and each
   parent directory for `.deco/config.toml`.
4. The first match is the project configuration. Its containing project
   directory is the project root.
5. If no match is found, the command fails with exit code `2`.

Symlinks in the selected project path must be resolved before Deco compares
project identities or applies ownership labels.


### Validation

Every project command must parse and validate `.deco/config.toml` before performing a Podman operation or running a hook.

Named project selection is the exception: Deco may query Podman to locate managed containers and identify the project root using ownership labels. Once the project root is identified, Deco must validate its configuration before performing any further Podman operations.

Validation follows the TOML specification and must include configuration rules, filesystem requirements, and Podman compatibility checks.

Commands must not partially apply an invalid configuration. In particular, `assemble` and `refresh` must complete validation before creating, rebuilding, or replacing any resources.

### Resource ownership

Every image built by Deco and every container created by Deco must receive
these labels:

| Label | Value |
| --- | --- |
| `dev.deco.managed` | `"true"` |
| `dev.deco.project` | `project.name` |
| `dev.deco.project-root` | Canonical absolute project-root path |
| `dev.deco.user-identity` | `uid:<resolved uid>,gid:<resolved gid>` when `[user]` uses `keep-id` or `host-user` |

Deco identifies the current project's resources by configured name and
ownership labels. A resource with the configured name but different or
missing ownership labels is a conflict and must not be changed automatically.

The `dev.deco.user-identity` label is applied to containers using `keep-id` or `host-user` and records the host and container identities used when the container was created.

Deco uses this label to detect changes to user identity configuration. When the configured mapping differs from an existing container's mapping, Deco must require container recreation.

Changes to user identity mapping alone do not require rebuilding the image.

### Common output rules

- Normal human-readable output is written to stdout.
- Errors, warnings, and verbose diagnostics are written to stderr.
- Human output is intended for terminal users and is not a stable parsing
  interface.
- Commands must not emit ANSI styling when stdout is not a terminal or when
  the `NO_COLOR` environment variable is present.
- Secrets and complete environment-variable values must not appear in normal
  or verbose output.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Operation completed successfully. |
| `1` | Podman, build, hook, action, or other runtime operation failed. |
| `2` | Command usage or project configuration is invalid. |
| `3` | Podman is not installed or not usable. |
| `4` | Resource state conflicts with the requested operation, or an unsafe removal was refused. |

`exec`, `run`, and hook-driven commands should return the executed process's
exit status when it is available. If the process terminated by signal or its
status cannot be represented directly, Deco returns `1` and reports the
termination on stderr.

## 4. Informational output formats

`info`, `list`, and `actions` accept:

```text
--format <human|json>
```

The default is `human`. JSON output must be valid UTF-8 JSON followed by one
newline and must contain no additional stdout text. Fields defined below are
stable for v1 and must always be present. An unavailable scalar value is
`null`; collections are empty arrays rather than `null`.

Future v1-compatible releases may add JSON fields but must not remove, rename,
or change the type or meaning of existing fields.

## 5. Commands

### `deco validate`

```text
deco validate
```

Discovers the project, parses `.deco/config.toml`, applies defaults, and performs
all validation that does not require building or running the image. It must
not create, alter, start, or remove Podman resources.

Successful human output identifies the validated configuration path.
Validation errors must include the full TOML key path when applicable.

### `deco init`

```text
deco init [PATH] [--template <NAME>] [--replace] [--dry-run]
deco init --list-templates
```

Initializes Deco configuration for `PATH`, or the current directory when
`PATH` is omitted. If `PATH` does not exist, Deco creates it as a directory.
If `PATH` exists, it must be a directory.

`init` creates only:

```text
<PATH>/.deco/config.toml
<PATH>/.deco/build/Containerfile
```

A template must not create or modify application source, project manifests,
lock files, or any file outside `.deco/`.

#### Init options

| Option | Description |
| --- | --- |
| `-t, --template <NAME>` | Select one built-in Deco template. |
| `--list-templates` | List built-in template names and descriptions, then exit. |
| `-R, --replace` | Replace existing Deco target files. |
| `-d, --dry-run` | Print the files that would be created or replaced without writing anything. |

The canonical selection option is singular: `--template`. `--templates` is
not an alias.

Template names must match `[a-z][a-z0-9-]*` and are case-sensitive. The
concrete template catalog is maintained by the implementation rather than
fixed by this specification. It may contain templates such as `go`, `rust`,
or `python`.

`--list-templates` is a standalone operation. It must reject `PATH`,
`--template`, `--dry-run`, or `--replace` when combined with it. Human output
must display one entry per template with at least its name and a short
description of the intended development environment. Entries must be sorted
by template name.

Example:

```text
$ deco init --list-templates
alpine      Alpine Linux development container
debian      Debian development container
fedora      Fedora development container
go          Go development container
python      Python uv development container
podman      Podman development container
rust        Rust development container
tumbleweed  OpenSUSE Tumbleweed development container
```

An unknown template is a usage error. The error must include the requested
name and direct the user to `deco init --list-templates`.

Each template must produce a `config.toml` valid under the TOML specification
and a compatible Containerfile. The generated config's `project.name` is
derived from the target directory's final path component as follows:

1. Convert ASCII letters to lowercase.
2. Replace each run of characters outside `[a-z0-9._-]` with `-`.
3. Remove leading and trailing `.`, `_`, and `-` characters.
4. Truncate to 128 characters and remove any trailing punctuation created by
   truncation.
5. Use `deco-project` if the result is empty.

Deco-created containers must be created with Podman's init process enabled
so signals are forwarded to the configured command and orphaned processes are
reaped.

When creating a container, Deco must apply the advanced runtime settings
from `[container]`, including privileged mode, devices, capability add/drop,
security options, environment variables, env files, and namespace modes. If
Podman cannot implement a configured option with the behavior defined by the
TOML specification, Deco must fail before creating or replacing the container.

If either target file already exists, `init` must fail without changing
anything unless `--replace` is supplied. `--replace` atomically replaces only
`.deco/config.toml` and `.deco/build/Containerfile`; unrelated `.deco/` content is
preserved. If creation or replacement fails, Deco should leave the original
files intact.

Dry-run output must show:

1. The resolved target directory.
2. The selected template and its description.
3. That the generated defaults target Podman.
4. Whether `.deco/` would be created.
5. Each file that would be created or replaced.
6. The generated contents or an equivalent clearly delimited preview.

Example:

```text
deco init ./service --template rust
deco init --template python --dry-run
```

### `deco assemble`

```text
deco assemble [--dry-run]
```

Prepares a usable development environment and returns without opening a
shell.

The operation is:

1. Discover and validate the project.
2. Verify Podman is available.
3. Build the configured image if it does not exist.
4. Create the configured container if it does not exist.
5. Start the container if it is stopped.
6. Run the lifecycle hooks required by the TOML specification.

When a new container is created, Deco runs `post_create` followed by
`post_start` after starting it. When an existing stopped container is started,
Deco runs only `post_start`. When the container is already running, `assemble`
makes no lifecycle change and repeats no hook.

An existing compatible image is reused. `assemble` does not rebuild merely
because build inputs changed; use `refresh` for an explicit rebuild.

`-d, --dry-run` displays the ordered operations without invoking Podman,
creating files, or running hooks.

### `deco refresh`

```text
deco refresh [--keep-image] [--volumes] [--dry-run]
```

Rebuilds the configured image, then recreates and starts the project
container. `--keep-image` skips the image rebuild and recreates only the
container from the existing configured image.

The operation is:

1. Validate the project and verify Podman is available.
2. If the existing container is running, run `pre_stop` and stop it.
3. Remove the existing container.
4. Unless `--keep-image` is set, rebuild the configured image.
5. With `--keep-image`, require the configured image to exist.
6. Create any missing configured named volumes.
7. With `--volumes`, remove and recreate configured owned named volumes.
8. Create and start the replacement container.
9. Run `post_create`, then `post_start`.

If no project container exists, `refresh` continues from the image step and
creates one. With `--keep-image`, a missing image is a resource-state error.
Configured named volumes are recreated only with `--volumes`; otherwise
existing owned named volumes are reused.

`-d, --dry-run` displays the complete ordered operation without invoking
Podman or hooks.

### `deco remove` and `deco rm`

```text
deco remove [--keep-image] [--force] [--keep-volumes] [--dry-run]
deco rm [--keep-image] [--force] [--keep-volumes] [--dry-run]
```

`rm` is an exact alias for `remove`.

By default, Deco removes the current project's container, configured owned
named volumes, and configured image. If the container is running, Deco runs
`pre_stop`, stops it, and then removes it. A missing project container is a
successful no-op for the container portion. `--keep-volumes` preserves
configured named volumes. `--keep-image` preserves the configured image. A
missing configured image is a successful no-op for the image portion.

When image removal is active, Deco must inspect all remaining containers that
reference the image after removing the project container:

- With no dependents, remove the image.
- With dependents and no `--force`, retain the image, report every dependent
  container, and exit `4`.
- With `--force`, stop and remove every dependent container, including
  containers not created by Deco, and then remove the image.

`--force` is valid only when image removal is active; combining `--force`
with `--keep-image` is a usage error and fails with exit code `2`. Before changing a
non-Deco dependent container, human output must clearly state its name or ID
and that it is not Deco-managed. `--force` is intentionally destructive and
must never imply automatic confirmation; specifying the flag itself is the
confirmation.

Hooks from other projects are not run while forcibly removing dependent
containers because their configuration and trust status are unknown.

`-d, --dry-run` displays the `pre_stop` hook, container stop, and container,
volume, and image removals in execution order — including every dependent
container `--force` would stop and remove, and any removal that would be
refused with exit code `4` — without invoking Podman or running hooks.

### `deco start`

```text
deco start [--dry-run]
```

Starts an existing project container and runs `post_start`. If the container
is already running, the command succeeds without repeating the hook. If the
container does not exist, it fails with exit code `4` and directs the user to
`deco assemble`.

`-d, --dry-run` displays whether the container would be started and the
`post_start` hook that would run, without invoking Podman or running hooks.

### `deco stop`

```text
deco stop [--dry-run]
```

For a running container, runs `pre_stop` and then stops it. If `pre_stop`
fails, the container remains running. If the container is already stopped,
the command succeeds without running the hook. A missing container fails with
exit code `4`.

`-d, --dry-run` displays the `pre_stop` hook and the stop that would run,
without invoking Podman or running hooks.

### `deco info`

```text
deco info [--format <human|json>]
```

Reports the current project's resolved configuration and Podman resource
state without changing it. The report includes project identity, Podman
version, image identity and existence, container identity and state, user
mode, workdir, mounts, published ports, configured hooks, and action names.

JSON output has this shape:

```json
{
  "project": {
    "name": "my-project",
    "description": "Example project",
    "root": "/home/user/my-project",
    "config": "/home/user/my-project/.deco/config.toml"
  },
  "podman": {
    "version": "5.0.0"
  },
  "image": {
    "name": "my-project-dev-image",
    "tag": "latest",
    "id": "sha256:...",
    "exists": true
  },
  "container": {
    "name": "my-project-dev-container",
    "container_id": "abc123",
    "exists": true,
    "state": "running"
  },
  "runtime": {
    "user_mode": "keep-id",
    "workdir": "/workspace",
    "shell": "bash"
  },
  "mounts": [],
  "dns": [],
  "ports": [],
  "hooks": ["post_create", "post_start"],
  "actions": ["dev", "test"]
}
```

`container.state` is one of `running`, `stopped`, `paused`, `unknown`, or
`null` when the container does not exist. Each `mounts` entry includes
`source`, `target`, `type`, `readonly`, and `relabel`; source may be `"-"`
for source-less mounts such as `tmpfs` and `devpts`. `dns` includes configured
network DNS server addresses. Each `ports` entry includes `host`, `container`,
`protocol`, and `bind`.

### `deco list`

```text
deco list [--format <human|json>]
```

Lists all Podman containers with
`dev.deco.managed="true"`. It does not require a project. Both running and
stopped containers are included and sorted by project name, then container
name.

Human output is a table containing project, container, state, image, and
project root.

JSON output is an array:

```json
[
  {
    "project": "my-project",
    "project_root": "/home/user/my-project",
    "container": "my-project-dev-container",
    "container_id": "abc123",
    "state": "running",
    "image": "my-project-dev-image:latest"
  }
]
```

An empty result is successful and produces an empty table or `[]`.

### `deco exec`

```text
deco exec [--dry-run] -- <COMMAND...>
```

Executes a non-interactive command in the project container as the configured
user and in `container.workdir`. The `--` separator is required. Deco passes the
arguments after `--` directly as an argument vector; it does not evaluate them
through `container.shell`.

If the existing container is stopped, Deco starts it and runs `post_start`
before executing the command. A missing container fails with exit code `4`
and directs the user to `deco assemble`.

At least one command argument is required. When Deco's stdin and stdout are
both terminals, `exec` allocates an interactive TTY and inherits stdin so
long-running commands can receive terminal input and interrupts such as
Ctrl-C. Otherwise, stdout and stderr are streamed directly, stdin is
inherited, and no TTY is allocated.

`-d, --dry-run` displays whether the container would be started (running
`post_start`) and the exact command that would be executed, without invoking
Podman, allocating a TTY, or running hooks.

Example:

```text
deco exec -- cargo test --workspace
```

### `deco shell`

```text
deco shell [--dry-run]
```

Opens an interactive TTY using `container.shell`, as the configured user and in
`container.workdir`.

If the existing container is stopped, Deco starts it and runs `post_start`.
A missing container fails with exit code `4` and directs the user to
`deco assemble`. Immediately before entering the shell, Deco runs `pre_enter`.
A failed `pre_enter` prevents shell entry.

`shell` requires Deco's stdin and stdout to both be terminals. If either is
not a terminal, the command fails before inspecting or mutating Podman
resources. `--dry-run` is exempt from the terminal requirement.

`-d, --dry-run` displays the planned container start, `post_start`, `pre_enter`,
and shell entry without requiring a terminal, invoking Podman, or running
hooks.

The shell process receives inherited terminal dimensions, environment, and
signals. Exiting the shell does not stop or remove the container.
Deco returns the shell process's exit status when it is available.

### `deco actions`

```text
deco actions [--format <human|json>]
```

Lists actions from `[actions]`, sorted by action name. It reads configuration
but does not require a container or a Podman operation.

Human output displays each action name and command.

JSON output is an array:

```json
[
  {
    "name": "dev",
    "command": "npm run dev"
  },
  {
    "name": "test",
    "command": "npm test"
  }
]
```

No configured actions is successful and produces an empty list.

### `deco run`

```text
deco run [--dry-run] <ACTION>
```

Runs the named configured action inside the project container as the
configured user, in `container.workdir`, using:

```text
<container.shell> -lc <action-command>
```

If the existing container is stopped, Deco starts it and runs `post_start`
before the action. A missing container fails with exit code `4`. An unknown
action is a usage error and must direct the user to `deco actions`.

When Deco's stdin and stdout are both terminals, `run` allocates an
interactive TTY and inherits stdin so long-running actions can receive terminal
input and interrupts such as Ctrl-C. Otherwise, stdout and stderr are streamed
directly, stdin is inherited, and no TTY is allocated. Exiting or interrupting
the action does not stop or remove the container.

`-d, --dry-run` displays whether the container would be started (running
`post_start`) and the action command that would run, without invoking Podman,
allocating a TTY, or running hooks.

### `deco completion`

```text
deco completion bash
```

Prints a Bash completion script to stdout. The command does not discover a
project, parse configuration, or inspect Podman.

The generated Bash completion must dynamically complete project names after
`-p` and `--project` from Deco-managed Podman containers. It must
also dynamically complete `deco run` action names by reading the current
project's `[actions]` table at completion time. Missing projects, an
unavailable Podman, and invalid configuration must produce no dynamic
completions and
must not print errors into the shell completion stream.

## 6. Hook and failure behavior

Hooks run in the order defined by the TOML specification and fail fast.

- A failed `post_create` leaves the newly created container running so the
  user can inspect it. `post_start` is not run.
- A failed `post_start` leaves the container running.
- A failed `pre_enter` prevents shell entry.
- A failed `pre_stop` prevents the requested stop, refresh, or normal removal.
- Podman or hook failure stops the current command; Deco must not continue to
  later lifecycle steps.

For `refresh`, failure after the old container has been removed must be
reported clearly as a partial operation. Deco must not silently restore an
outdated container.

## 7. Dry-run requirements

`init`, `assemble`, `refresh`, `remove`, `start`, `stop`, `exec`, `shell`, and
`run` support `-d, --dry-run`.

A dry run must:

- Perform argument parsing, project discovery, configuration parsing, and
  validation.
- Inspect host files and existing Podman state when needed to produce an
  accurate plan.
- Print operations in execution order.
- Identify resources by their resolved names.
- Print the exact Podman command that would be invoked for each engine
  operation, with secret and environment-variable values redacted as required
  by the common output rules.
- Mark conditional or destructive operations clearly.
- Avoid file writes, image builds, resource mutations, and hook execution.

A dry run fails normally when configuration is invalid or required Podman
inspection cannot be performed.

## 8. Conformance scenarios

A conforming implementation must cover at least these scenarios:

1. Podman availability is detected; when Podman is missing or unusable,
   commands fail with exit code `3`.
2. Project discovery works from the root and nested directories.
3. `init` lists sorted templates with descriptions and rejects incompatible
   `--list-templates` arguments.
4. Minimal and selected templates create only the two documented `.deco/`
   files; dry-run creates nothing.
5. `assemble` handles missing, stopped, and running containers with the
   correct hook behavior.
6. `refresh` rebuilds by default and supports container-only refresh with
   `--keep-image`.
7. `shell`, `exec`, and `run` start stopped containers but reject missing
   containers.
8. Normal image removal refuses dependent containers, while `--force` removes
   all dependents.
9. Human and JSON informational output follow their defined stdout and stderr
   contracts.
10. Unknown commands, options, templates, actions, and invalid TOML produce
    the documented errors and exit codes.
11. `remove`, `start`, `stop`, `exec`, `shell`, and `run` dry runs print the
    ordered plan and perform no Podman mutations or hook execution.

