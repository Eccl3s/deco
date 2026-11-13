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

Once implemented, Deco's intended workflow will be:

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

- OCaml
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
- [TOML Specification](specs/deco-toml.md) — Defines configuration fields, defaults, validation rules, and runtime settings.

## License

Deco is licensed under the GNU General Public License version 3.0 or later (GPL-3.0-or-later).

See [LICENSE](LICENSE) for details.
