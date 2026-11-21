# Deco

Deco is a command-line tool written in OCaml for creating repeatable, project-local development environments using Podman.

Each environment is defined by two files stored alongside the project:

- `.deco/config.toml` — Configures the development environment, including container settings, networking, mounts, lifecycle hooks, and actions.
- `.deco/build/Containerfile` — Defines the container image, including its operating system, development tools, and dependencies.

Deco aims to make development environments reproducible and easy to manage without requiring developers to manually configure and manage Podman containers.

> [!NOTE]
> Deco is currently in early development. Its specifications describe the intended v1 behaviour, but the implementation is not yet complete.

## Planned Features

Deco aims to support:

- Project initialization using built-in development environment templates.
- Declarative configuration through `.deco/config.toml`.
- Container image building with Podman.
- Persistent, project-local development containers.
- Interactive development shells.
- Execution of commands and named project actions.
- Container lifecycle management.
- Workspace mounts, networking, and environment configuration.
- Lifecycle hooks for container creation, startup, and shutdown.
- Configuration validation and diagnostic commands.

See [specs/](specs/) for the full CLI and configuration specifications.

## Getting Started

Deco currently implements `init`, `validate`, `assemble`, `refresh`, `exec`, `shell`, `start`, `stop`, `remove`, `info`, `list`, help, and version output. Other commands
below describe the planned workflow.

Validate an existing project with `deco validate` or select one explicitly with
`deco --project-dir PATH validate` (the option also works after the command).
Use `deco --help` for details and `deco --version` for the development version.
Validation checks configuration, defaults, host paths and identity without Podman
(unless the project is selected with `--project`; see below). Runtime
compatibility, namespace feasibility, and image account/executable checks remain
deferred; this is not full v1 validation conformance. Errors go to stderr with
exit code 2; success identifies the config path on stdout with exit code 0.

### Selecting a project

Project commands (`validate`, `assemble`, `refresh`, `exec`, `shell`, `start`,
`stop`, `remove`, and `info`) find their project in one of three ways:

- By default, Deco searches the current directory and its parents for
  `.deco/config.toml`.
- `--project-dir PATH` selects that directory, with no parent fallback.
- `-p NAME` or `--project NAME` selects an assembled project by its configured
  `project.name`, from any directory. Names are those shown by `deco list`:

  ```sh
  deco list
  deco stop -p my-project
  deco -p my-project exec -- cargo test
  ```

Both options may appear before or after the command, but not after the `--` of
`deco exec`. They are mutually exclusive, and `init` and `list` accept neither.

`--project` finds the managed containers labelled with that project name and
uses their recorded project root. The root must still contain a
`.deco/config.toml` whose `project.name` matches, and that configuration is
fully validated before any further Podman command. Ownership checks against the
loaded configuration are unchanged, so the labels only locate the project; they
never authorise changes on their own. Because the lookup queries Podman, it
needs Podman even with `--dry-run`, though it only reads container labels.

The lookup fails with exit code 2 when:

- no container records the name (assemble the project first, or use
  `--project-dir`)
- containers record more than one distinct root for it
- the recorded root is missing or has no `.deco/config.toml`
- the configuration there names a different project

In the ambiguous and mismatched cases, use `--project-dir` to choose the
directory explicitly. Root labels that are not absolute paths are ignored.
Unavailable Podman returns 3, and a failed Podman listing returns 1.

The intended full workflow will be:

Initialize a project:

```sh
deco init
```

This creates:

```text
my-project/
├── .deco/
│   ├── config.toml
│   └── build/
│       └── Containerfile
└── ...
```

Validate the configuration:

```sh
deco validate
```

Build and start the development environment:

```sh
deco assemble
```

Enter the development container:

```sh
deco shell
```

Stop the container:

```sh
deco stop
```

Start it again later:

```sh
deco start
```

These commands describe the planned interface and may not yet be available.

### Ownership conflicts

Deco labels every image and container it creates with the project name and the
absolute project root, and only changes resources whose labels match the
current project. When a resource with the configured name carries other labels,
the command refuses with exit code 4. The message says what owns the resource
and lists each conflicting label with its expected and found values:

```text
deco: container my-project-dev-container belongs to Deco project "other-project"
  dev.deco.project: expected "my-project", found "other-project"
  dev.deco.project-root: expected "/home/me/my-project", found "/home/me/other-project"
  To keep it, set [container].name in .deco/config.toml to use a different name.
```

#### Known limitation: moved projects

Because ownership records the absolute project root, moving or renaming the
project directory leaves its image and container labelled with the old root.
Deco cannot tell this apart from another project with the same name elsewhere,
so it refuses to change them, `deco remove` included. For this case only, the
message names the old root and the Podman command that removes the resource:

```text
deco: container my-project-dev-container belongs to a Deco project with the same name at another location
  dev.deco.project-root: expected "/home/me/src/my-project", found "/home/me/my-project"
  If the project was moved from /home/me/my-project and that copy no longer exists, remove the old container with:
    podman rm my-project-dev-container
  Otherwise, set [container].name in .deco/config.toml to use a different name.
```

Run that command only if the old copy is gone. The image reports the same
conflict and has its own `podman rmi` command. Once both are removed,
`deco assemble` creates fresh resources for the new location.

## Configuration

Deco uses two files to define a development environment.

### `.deco/config.toml`

The configuration file describes how Deco builds and manages the development container.

### `.deco/build/Containerfile`

The `Containerfile` defines the image used for the development environment.

It follows Dockerfile syntax and specifies the base operating system, installed packages, development tools, and runtime configuration.

For example:

```dockerfile
FROM debian:trixie-slim

ARG USER_NAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g "${USER_GID}" "${USER_NAME}" \
    && useradd -m -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"

ENV HOME=/home/${USER_NAME}

USER ${USER_NAME}

WORKDIR /workspace

CMD ["sleep", "infinity"]
```

By default, Deco uses `.deco/build` as the image build context and `Containerfile` as the build definition.

These locations can be customized through the `[build]` section of `.deco/config.toml`.

The build context is separate from the project workspace. Files outside the build context are not available to `COPY` and `ADD` instructions during the image build.

The project workspace can instead be mounted into the running container using `[mounts.workspace]`.

When using keep-id mode, Deco configures Podman's user namespace to map the host user's UID and GID to the configured container UID and GID. This allows the development environment to use an existing container user without requiring its UID or GID to match those of the host user.

### Building and Refreshing

Create the development environment:

```sh
deco assemble
```

Deco builds the image if it does not exist, creates the container if necessary, and starts it.

Existing compatible images and containers are reused.

To rebuild the image and recreate the container:

```sh
deco refresh
```

Changes to the Containerfile do not automatically trigger a rebuild when running `deco assemble`.

## Installation

Deco is not yet available as an installable release.

Installation instructions will be added when the initial implementation is ready.

## Building From Source

Deco is written in OCaml and uses Dune as its build system and OPAM for dependency management.

### Prerequisites

- OCaml 5.5.2 or newer; CI tests 5.5.2.
- OPAM
- Dune
- [Podman](https://podman.io/docs/installation)

Podman is required for container operations.

### Build

From the project root, install dependencies:

```sh
opam install . --deps-only --with-test
```

Build the project:

```sh
dune build
```

Run the development executable:

```sh
dune exec deco -- --help
```

These instructions assume the initial Dune project and executable have been configured.

## Development

Deco is developed using OCaml, Dune, and OPAM.

Build the project:

```sh
dune build
```

Run tests:

```sh
dune runtest
```

Check compilation:

```sh
dune build @check
```

Check formatting:

```sh
dune build @fmt
```

Format the source code:

```sh
dune fmt
```

Before submitting changes, run:

```sh
dune build
dune build @check
dune build @fmt
dune runtest
```

## Specifications

Deco is developed against two specifications:

- [CLI Specification](specs/deco-cli.md) — Defines commands, options, output formats, exit codes, and lifecycle behaviour.
- [Config TOML Specification](specs/deco-config.md) — Defines configuration fields, defaults, validation rules, and runtime settings.

## License

Deco is licensed under the GNU General Public License version 3.0 or later (GPL-3.0-or-later).

See [LICENSE](LICENSE) for details.

`[user]` supports `keep-id` and `image`. Explicit UID/GID values
must be in 0–4294967294 and fit an OCaml `int`. Image mode, including an
omitted mode, forbids UID/GID settings; this is a restriction beyond the v1 specification.

### Build and release versions

The CLI derives its version during the build from Dune package metadata, or
from Git (including an untagged commit identifier). There is no runtime Git
dependency and no hardcoded development version.

Before preparing a release archive, embed the release version in `dune-project`
and regenerate `deco.opam` in a disposable release checkout. Build and verify
`deco --version` before archiving. Metadata-free archives without Git fail to
build; raw GitHub source archives must first receive explicit version metadata.
The existing release workflow does not prepare these archives automatically.

### Initialize a project

Run `deco init [PATH]` to create `.deco/config.toml` and
`.deco/build/Containerfile`, using the Debian template by default.
`deco init --list-templates` lists alpine, debian, fedora, go, podman, python,
rust, and tumbleweed. Select one with `--template NAME` or `-t NAME`.
The existing built-in Containerfiles are copied unchanged.

Use `--dry-run` (`-d`) to preview generated files without writing, or
`--replace` (`-R`) to replace the two target files while preserving unrelated
content. Existing targets otherwise cause an error. Replacement is atomic per
file, with rollback on ordinary failures; the pair is not crash-atomic and
concurrent external edits are unsupported. Symlinks inside the output structure
are rejected.

Generated configuration explicitly selects keep-id and a workspace at
`/workspace`; UID/GID keys are omitted. Init performs no host identity lookup,
build-argument generation, image builds, or Podman operations. Generated
configuration preserves template settings unchanged. Recognized planned
settings are accepted and structurally checked but not applied. `deco validate`
lists ignored key paths without values; other commands do not report them.
Acceptance is not full v1 validation or implementation of those features.

Each built-in template consists of `<name>.toml` and `<name>.Containerfile`
in `lib/templates`, embedded at build time. Init substitutes `{{project_name}}`,
`{{image_name}}`, and `{{container_name}}` in the TOML, preserving other text.
These tokens belong inside quoted TOML values. Containerfiles remain unchanged;
init never strips planned settings from generated TOML. Missing partners and
unknown or unterminated placeholders fail the embedding build.

### Assemble a supported configuration

`deco assemble` builds a missing image, creates a missing container, and starts
it. Compatible running containers are reused. Configuration must validate first;
all eight built-in templates are accepted,
with recognized planned settings ignored as described below.
For a minimal supported setup, use `.deco/config.toml`:

```toml
[project]
name = "example"
```

And `.deco/build/Containerfile`:

```dockerfile
FROM alpine:3.23
CMD ["sleep", "infinity"]
```

Run `deco assemble --dry-run` (or `-d`) to preview four high-level steps and complete,
multiline Podman build/create commands without invoking Podman or writing files.
The image ID appears as a placeholder resolved during execution. Use `--project-dir PATH` before or after `assemble` to select a project.
`--project NAME` is accepted too, but only finds a project that already has a
managed container; see [Selecting a project](#selecting-a-project).

Exit codes are 0 for success, 1 for runtime failure, 2 for invalid configuration or
usage, 3 for unavailable Podman, and 4 for ownership, compatibility, or state
conflicts. Failed operations retain partial resources; inspect them with Podman
before retrying. Assemble never automatically rebuilds or replaces resources.
Hooks and advanced configuration remain unsupported. Automated CLI tests use fake
Podman responses; disposable live integration coverage is a separate step.

Compact build output requires both stdin and stdout to be terminals. Press `t`
to expand the full log permanently. Redirected output, `NO_COLOR`, and
`TERM=dumb` use normal full-log streaming instead.

### Execute a command

Run `deco exec -- COMMAND ARG...` in an assembled environment, for example
`deco exec -- cargo test`. The separator is required. Arguments are passed
without shell evaluation. Compatible stopped containers start automatically;
missing containers require `deco assemble`. Hooks remain unsupported.

Stdin is inherited; a TTY is allocated when stdin and stdout are both terminals.
Command exit codes pass through unchanged; abnormal termination returns 1.
Use `deco exec --dry-run -- COMMAND` to preview without invoking Podman.

### Local runtime and SELinux detection

Deco explicitly uses local Podman (`--remote=false`), ignoring implicit
remote connection selection. Assemble and exec use a lightweight version check and resolves
SELinux status only when it affects workspace relabel compatibility. It checks
local sysfs first and falls back to Podman info when the result is unknown.
Permissive SELinux is treated as enabled. Detection is reused within one command
invocation; ownership and compatibility checks still run on every invocation.

Successful resource inspections avoid separate existence checks. Assemble and
exec inspect the configured image and container concurrently before ownership
and compatibility validation. Failed inspections use an existence check to
distinguish missing resources from runtime errors. Mutations and subsequent
verification remain sequential.

### Enter the development shell

Run `deco shell` to enter `container.shell` as the configured user and workdir.
Both stdin and stdout must be terminals. Compatible stopped containers start
first; exiting the shell leaves the container running. Normal exit codes pass
through; abnormal termination returns 1. Podman retains its existing container
environment behavior; arbitrary host environment variables are not copied.

Use `deco shell --dry-run` (or `-d`) without a terminal to preview entry.
The `post_start` and `pre_enter` hooks remain deferred and are not executed.
Run `dune build @test-shell-pty` for opt-in Linux PTY tests using Python 3's
standard library and fake Podman; ordinary tests require no Python.

### Start the development container

Run `deco start` to start an existing stopped project container, or
`deco start --dry-run` (`-d`) to preview without Podman. Success prints
`Started <name>`, or `Already running: <name>` when nothing needed to change.
Start never builds or creates resources: a missing container or image returns 4
and directs you to `deco assemble`.

Start runs the same checks as `exec` and `shell` before starting anything: the
configured image must exist, both resources must carry this project's ownership
labels, and the container must match the configuration (image, init, user
strategy, working directory, and workspace mount, including SELinux relabelling).
Incompatible containers and unsupported states such as `paused` return 4; use
`deco refresh` to recreate an incompatible container. After a start, Deco
reinspects the same container and requires it to be running with unchanged
container and image IDs. A failed start, or a container that is not running
afterwards, returns 1; changed IDs return 4. When the start command completed
but verification failed, the error says so. Invalid configuration/usage returns
2 and unavailable Podman 3.

Unlike the full v1 specification, the `post_start` hook is not run; the dry-run
preview notes this. Use `-p NAME` to start a listed project from any directory,
for example `deco start -p my-project`.

### Stop the development container

Run `deco stop` to stop a running managed container, or `deco stop --dry-run`
(`-d`) to preview without Podman. Success prints `Stopped <name>` or
`Already stopped: <name>`. Normal configuration validation is required, followed
by container ownership and state checks; image and environment compatibility
are not required. Missing/unmanaged containers and unsupported states return 4;
invalid configuration/usage returns 2, unavailable Podman 3, and runtime failure 1.
The `pre_stop` hook remains deferred. Stop does not remove resources.

Run the opt-in disposable integration check with an existing local image that
supports `sleep` (no images are pulled):

```sh
DECO_TEST_IMAGE=your-local-image python3 test/stop_podman.py _build/default/bin/deco.exe
```

### Remove the development environment

Run `deco remove` to stop and remove the owned project container and remove its
owned configured image. Missing resources are successful no-ops. Use
`--keep-image` to skip all image operations, or `-d`/`--dry-run` for a conditional
preview without Podman queries or live dependency enumeration.

Success reports removed or already-absent resources. An image with remaining
container dependents is retained; all dependent IDs/names are reported with exit
code 4. Unmanaged resources and unsupported states also return 4. Invalid
configuration/usage returns 2, unavailable Podman 3, and runtime failures 1.
Failures report completed commands without claiming verification succeeded.

Unlike the full v1 specification, `remove` does not implement `--force`,
`--keep-volumes`, named-volume removal, or lifecycle hooks. Removal never changes
unrelated dependent containers or prunes parent images. Only `deco remove` is
supported as the removal command.

Run the opt-in live test with an existing local base image supporting `sleep`:

```sh
DECO_TEST_IMAGE=your-local-image python3 test/remove_podman.py _build/default/bin/deco.exe
```

The test builds disposable ownership-labelled child images without pulling,
cleans up only its test resources, and preserves the supplied base image.

### List managed containers

Run `deco list` from any directory to list every container labelled
`dev.deco.managed=true`, running or stopped, across all projects. No project is
needed, and `--project-dir` and `--project` are rejected. Entries are sorted by
project, then container name. Pass a listed project's name to `-p`/`--project`
to act on it from anywhere, for example `deco stop -p my-project`.

```text
$ deco list
┌────────────┬──────────────────────────┬─────────┬───────────────────────────────────────┬───────────────────────┐
│ PROJECT    │ CONTAINER                │ STATE   │ IMAGE                                 │ PROJECT ROOT          │
├────────────┼──────────────────────────┼─────────┼───────────────────────────────────────┼───────────────────────┤
│ my-project │ my-project-dev-container │ running │ localhost/my-project-dev-image:latest │ /home/user/my-project │
│ other      │ other-dev-container      │ exited  │ localhost/other-dev-image:latest      │ /home/user/other      │
└────────────┴──────────────────────────┴─────────┴───────────────────────────────────────┴───────────────────────┘
```

The human table is for reading, not parsing. Use `--format json` (before or
after the command) for a stable array that also includes full container and
image IDs:

```sh
deco list --format json
```

```json
[
  {
    "project": "my-project",
    "project_root": "/home/user/my-project",
    "container": "my-project-dev-container",
    "container_id": "<full container ID>",
    "state": "running",
    "image": "localhost/my-project-dev-image:latest",
    "image_id": "<full image ID>"
  }
]
```

`state` is Podman's own state, such as `running`, `exited`, or `created`.
Missing labels or images are `null` in JSON and `-` in the table. With no
managed containers, the table form prints `No Deco-managed containers.` and the
JSON form prints `[]`; both succeed.

`list` reports labels as recorded and performs no ownership checks, so an
entry is not proof that Deco created the container. Unavailable Podman returns
3, and a failed or malformed Podman listing returns 1.

### Show project information

Run `deco info` to report the project's resolved configuration and the state of
its image and container. It only queries Podman and never changes anything, so
it is safe to run at any time; use `-p NAME` to inspect a listed project from
any directory.

```text
$ deco info
Project
  Name:        my-project
  Description: Deco Debian development environment
  Root:        /home/user/my-project
  Config:      /home/user/my-project/.deco/config.toml

Podman
  Available:   yes
  Version:     5.7.0

Image
  Name:        my-project-dev-image
  Tag:         latest
  ID:          <full image ID>
  Exists:      yes
  Created:     2026-11-11 09:14 UTC (9 days ago)
  Owned:       yes

Container
  Name:        my-project-dev-container
  ID:          <full container ID>
  Exists:      yes
  State:       stopped (exited)
  Created:     2026-11-12 08:30 UTC (8 days ago)
  Owned:       yes
  Compatible:  no
    - Container init is disabled

Runtime
  User mode:   keep-id
  Workdir:     /workspace
  Shell:       bash

Mounts
  /home/user/my-project -> /workspace (bind, read-write, relabel private)

DNS
  none

Ports
  none

Hooks
  none

Actions
  none

Ignored planned settings (not applied yet):
  container.cap_drop
  network.mode
```

`State` is `running`, `stopped`, `paused`, or `unknown`, followed by Podman's
own state when it differs. `Owned` says whether the resource carries this
project's ownership labels, and `Compatible` whether the container matches the
configuration as `exec`, `shell`, and `start` require; it is evaluated only when
both resources exist and are owned, and each mismatch is listed. Unknown values
are `-`. Values are escaped as in `deco list`. The report is informational: any
command that later uses a resource verifies it again.

Use `--format json` (before or after the command) for a stable object:

```json
{
  "project": {
    "name": "my-project",
    "description": "Deco Debian development environment",
    "root": "/home/user/my-project",
    "config": "/home/user/my-project/.deco/config.toml"
  },
  "podman": { "available": true, "version": "5.7.0" },
  "image": {
    "name": "my-project-dev-image",
    "tag": "latest",
    "id": "<full image ID>",
    "exists": true,
    "created": "2026-11-11T09:14:02Z",
    "owned": true
  },
  "container": {
    "name": "my-project-dev-container",
    "id": "<full container ID>",
    "exists": true,
    "state": "stopped",
    "podman_state": "exited",
    "created": "2026-11-12T08:30:45Z",
    "owned": true,
    "compatible": false,
    "incompatibilities": ["Container init is disabled"]
  },
  "runtime": { "user_mode": "keep-id", "workdir": "/workspace", "shell": "bash" },
  "mounts": [
    {
      "source": "/home/user/my-project",
      "target": "/workspace",
      "type": "bind",
      "readonly": false,
      "relabel": "private"
    }
  ],
  "dns": [],
  "ports": [],
  "hooks": [],
  "actions": []
}
```

Timestamps are UTC with second precision, so JSON output does not change
between runs. A missing resource has `exists: false` and `null` for its `id`,
`created`, and `owned`; `compatible` is `null` unless it was evaluated.

`info` exits 0 whenever it can report, including when resources are missing,
unowned, or incompatible. When Podman is unavailable it still prints the full
report, with `podman.available` false and every Podman-derived value `null`
(`-` in human output), reports the problem on stderr, and exits 3. With
`-p NAME` the project itself cannot be located without Podman, so that case
exits 3 without a report. Invalid configuration or usage returns 2 and any
other Podman failure 1, without a report.

Unlike the full v1 specification, `dns`, `ports`, `hooks`, and `actions` are
always empty and only the workspace mount is reported, because those settings
are not applied yet; any that are configured appear under
`Ignored planned settings` in the human report instead.

### Planned configuration compatibility

All eight built-in templates can be initialized, validated, and previewed without
editing their files. `deco validate` prints ignored paths under
`Ignored planned settings (not applied yet):` on stdout and succeeds;
`deco info` ends its human report with the same list. Other commands silently
ignore those settings. Values are not printed.

Only documented v1 keys are tolerated. Unknown keys, nested typos, wrong types,
invalid TOML, and errors in implemented fields still fail. Planned fields receive
structural/type checks only: semantic constraints such as port ranges, capability
names, namespace conflicts, and host path existence are deferred.

Capabilities, network settings, environment injection, devices/security options,
additional mounts, secrets, actions, and hooks remain inactive. In particular,
accepting the Podman template does not enable its nested-Podman setup, and
accepting capability-drop settings does not apply capability restrictions.
This compatibility policy lasts until each setting is implemented; the v1
specification continues to describe the behavior expected from future releases.

Run the opt-in default-template workflow check with:

```sh
python3 test/template_podman.py _build/default/bin/deco.exe
```

This builds the unchanged Debian template (including image pulls and package
installation), exercises validate/assemble/exec/stop/remove in a temporary project,
and cleans up only its owned resources without pruning parent images.
