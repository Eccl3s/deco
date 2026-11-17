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

Deco currently implements `init`, `validate`, `assemble`, `exec`, `shell`, `stop`, `remove`, help, and version output. Other commands
below describe the planned workflow.

Validate an existing project with `deco validate` or select one explicitly with
`deco --project-dir PATH validate` (the option also works after the command).
Use `deco --help` for details and `deco --version` for the development version.
Validation checks configuration, defaults, host paths and identity without Podman.
Podman-backed `--project` lookup, runtime compatibility, namespace feasibility,
and image account/executable checks remain deferred; this is not full v1
validation conformance. Errors go to stderr with exit code 2; success identifies
the config path on stdout with exit code 0.

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

These commands describe the planned interface and may not yet be available.

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

For v0.1.0, `[user]` supports `keep-id` and `image`. Explicit UID/GID values
must be in 0–4294967294 and fit an OCaml `int`. Image mode, including an
omitted mode, forbids UID/GID settings; this is an additional v0.1.0 restriction.

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
build-argument generation, image builds, or Podman operations. Generated config preserves the template settings, including active settings not
yet supported by the decoder. Consequently, generated templates currently fail
`deco validate` with unsupported-key errors. Init does not verify image builds.

Each built-in template consists of `<name>.toml` and `<name>.Containerfile`
in `lib/templates`, embedded at build time. Init substitutes `{{project_name}}`,
`{{image_name}}`, and `{{container_name}}` in the TOML, preserving other text.
These tokens belong inside quoted TOML values. Containerfiles remain unchanged;
unsupported TOML settings are never silently stripped. Missing partners and
unknown or unterminated placeholders fail the embedding build.

### Assemble a supported configuration

`deco assemble` builds a missing image, creates a missing container, and starts
it. Compatible running containers are reused. Configuration must validate first;
generated templates still contain unsupported settings and require manual editing.
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

Deco v0.1.0 explicitly uses local Podman (`--remote=false`), ignoring implicit
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

Unlike the full v1 specification, v0.1.0 does not implement `--force`,
`--keep-volumes`, named-volume removal, or lifecycle hooks. Removal never changes
unrelated dependent containers or prunes parent images. Only `deco remove` is
supported as the removal command.

Run the opt-in live test with an existing local base image supporting `sleep`:

```sh
DECO_TEST_IMAGE=your-local-image python3 test/remove_podman.py _build/default/bin/deco.exe
```

The test builds disposable ownership-labelled child images without pulling,
cleans up only its test resources, and preserves the supplied base image.
