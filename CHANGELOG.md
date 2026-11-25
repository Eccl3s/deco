# Changelog

All notable changes to Deco are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Deco follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, minor
releases may change behaviour.

## [Unreleased]

### Added

- Deco labels the containers it creates with `dev.deco.create-digest`, a hash
  of the create-time settings that inspection cannot compare reliably. A
  container whose recorded hash differs from the configuration's is
  incompatible, and `deco refresh` recreates it. Containers created without
  the label are treated as having those settings unset, so existing containers
  stay compatible.
- Container security options: `container.privileged`, `devices`, `cap_add`,
  `cap_drop` and `security_options` are validated and passed to
  `podman create`, and they contribute to `dev.deco.create-digest`. Earlier
  releases accepted them but did not apply them; in particular, the
  templates' `cap_drop = ["ALL"]` now takes effect.
- `deco info` reports the security options in a `Security` section and a JSON
  `security` object, and the `deco trust` review lists them, flagging
  privileged mode, devices, added capabilities and security options.
- `assemble` and `refresh` refuse `cap_add` entries outside an image's
  `io.containers.capabilities` label, which Podman cannot apply, with exit
  code 4 before creating or removing a container.
- `test/templates_podman.py`, an opt-in live check of every template.
- Container environment: `[container.environment]` and `container.env_files`
  are validated and passed to `podman create` as `--env` and `--env-file`,
  with values passed literally. Env files must be existing regular files,
  resolved from the project root. Earlier releases accepted these settings but
  did not apply them; in particular, the `python` template's `UV_LINK_MODE`
  now takes effect. Variables and env file paths contribute to
  `dev.deco.create-digest`; env file contents do not, so run `deco refresh`
  after editing an env file.
- `deco info` reports the environment in an `Environment` section and a JSON
  `environment` object, and the `deco trust` review lists it, flagging env
  files outside the project. Only variable names and env file paths are shown:
  values never appear in previews, reports or the review.

### Changed

- Hooks and actions run as `<container.shell> -c <command>` instead of `-lc`,
  so they see the image's environment, as `deco exec` and `deco shell` do.
  Login shells on Debian, Ubuntu and Alpine images reset `PATH` from
  `/etc/profile`, which hid tools such as `go` and `cargo` that images add to
  `PATH`. Commands that relied on `/etc/profile` or `~/.profile` must now
  source them, for example `. ~/.profile && make test`.

### Fixed

- The go, rust and python templates build: they defaulted to Alpine base
  images while installing packages with `apt-get`, and now use Debian trixie.
- The podman template no longer sets `cap_add`, which its base image's
  `io.containers.capabilities` label made Podman unable to apply.

### Upgrade notes

- Containers created from the templates, or from any configuration that sets
  a security option, are now incompatible until `deco refresh` recreates them
  with the options applied. The same holds for configurations that set
  `[container.environment]` or `container.env_files`, including those
  generated from the `python` template.
- Projects generated from earlier templates keep their old files:
  - podman: remove `cap_add` from `.deco/config.toml`, or `assemble` refuses it.
  - go and rust: set `BASE_VARIANT = "trixie"` in `[build.args]`.
  - python: change `-alpine` to `-trixie` in the Containerfile's `FROM` line.

  After editing by hand, approve `.deco/` again with `deco trust`.
  `deco init --replace` instead regenerates both files and approves them.

## [0.3.0] - 2026-11-22

Developer workflows: lifecycle hooks, named actions, and configuration trust
that must approve `.deco/` before Deco acts on it.

### Added

- Lifecycle hooks. The `[hooks]` table's `post_create`, `post_start`,
  `pre_enter` and `pre_stop` commands run inside the container as
  `<container.shell> -lc <command>`, as the configured user and in
  `container.workdir`. `post_create` runs on a container's first start and
  `post_start` after every start Deco performs, in `assemble`, `refresh`,
  `start`, `exec`, `run` and `shell`; `pre_enter` runs before `shell` enters
  the container; `pre_stop` runs before `stop`, `remove` and `refresh` stop a
  running container. Hook output goes to stderr. A failing hook stops the
  command, and Deco exits with the hook's status. Dry runs list the hooks that
  would run.
- Named actions. The `[actions]` table maps names to shell commands.
  `deco actions` lists them, as a table or with `--format json`, without
  needing trust or Podman.
- `deco run NAME` runs an action in the container like `deco exec`: it starts
  a stopped container (running its hooks), passes the action's exit code
  through, and supports `--dry-run` and `-p NAME`.
- Configuration trust. `assemble`, `refresh`, `start`, `stop`, `remove`,
  `exec`, and `shell` now refuse with exit code 5 until the project's `.deco/`
  directory has been approved, and refuse again when anything in it changes,
  listing what changed. Dry runs still work and print a note. Existing
  projects need `deco trust` once after upgrading.
- `deco trust` reviews the configuration's security-relevant settings and
  approves it after confirmation, or with `--yes`. `--dry-run` shows the
  review only, `--show` prints the trust state, and `--revoke` removes every
  approval. Approvals are kept in `$XDG_STATE_HOME/deco/trust/`.
- `deco init` approves the configuration it writes.
- `deco info` reports the trust state, digest, last approval time, and changed
  entries.
- `--no-hooks` for `stop` and `remove` skips the `pre_stop` hook, so they work
  on configuration that is not trusted, with a warning.

### Changed

- `deco info` reports the configured hook and action names, and
  `deco validate` no longer lists `hooks` and `actions` as ignored planned
  settings.
- Deco labels the containers it creates with `dev.deco.shell`, so `pre_stop`
  can be skipped with a warning when the container's shell no longer matches
  the configuration.
- Ownership conflicts now name the image or container and say why it is not
  this project's: it was not created by Deco, it belongs to another Deco
  project, or it belongs to a project with the same name at another root. Each
  conflicting label is listed with its expected and found values, followed by
  a recovery hint. Removing the resource is suggested only for a moved
  project, and only if its old copy no longer exists.

### Known limitations

- Moving or renaming a project directory leaves its image and container owned
  by the old root, so Deco refuses to change them, `deco remove` included.
  Remove them with the `podman rm` and `podman rmi` commands the error prints,
  then run `deco assemble`.

## [0.2.0] - 2026-11-20

Better lifecycle management: restart, rebuild, inspect and list environments,
and select projects by name from anywhere.

### Added

- `deco refresh` rebuilds the image and recreates the container, replacing the
  old container only after the new image is built. `--keep-image` recreates the
  container from the existing image. `-d`/`--dry-run` previews the steps.
- `deco start` starts an existing stopped container after the same ownership
  and compatibility checks as `exec` and `shell`, then verifies that it is
  running. It never builds or creates resources.
- `deco info` reports the project's configuration and the state of its image
  and container: existence, IDs, creation times and age, ownership, Podman
  state, and compatibility with each mismatch listed. It is read-only. When
  Podman is unavailable it still prints the report and exits 3.
- `deco list` lists every Deco-managed container across all projects, running
  or stopped, from any directory.
- `--format human|json` for `info` and `list`, with a stable JSON shape.
- `-p NAME`/`--project NAME` selects an assembled project by its configured
  name from any directory, for every project command. The project root is
  located from container labels and its configuration is fully validated
  before use.

### Changed

- A failure to launch Podman is reported as Podman being unavailable (exit
  code 3) by every command, with a plain explanation such as "Podman was not
  found on PATH."
- Messages no longer name a specific release. Ignored planned settings are
  listed under `Ignored planned settings (not applied yet):`.

### Fixed

- Help and error output written to a pipe or file no longer contains ANSI
  styling when `TERM` is set.
- Commands that find the configured image missing now direct you to run
  `deco assemble`.
- `deco validate` escapes control characters in ignored setting paths, so an
  authored key cannot inject terminal sequences.

### Known limitations

- Lifecycle hooks are not run yet; in particular `start` does not run
  `post_start`, and its dry run says so.
- `deco info` reports `dns`, `ports`, `hooks` and `actions` as empty and
  reports only the workspace mount, because those settings are not applied
  yet. Configured values appear under ignored planned settings instead.

## [0.1.0] - 2026-11-18

First release: working project-local development containers in Podman.

### Added

- `deco init` creates `.deco/config.toml` and `.deco/build/Containerfile` from
  a template: alpine, debian, fedora, go, podman, python, rust or tumbleweed.
- `deco validate` checks the configuration, defaults, host paths and user
  identity without Podman.
- `deco assemble` builds a missing image, creates a missing container and
  starts it, reusing compatible existing resources.
- `deco exec` runs a command in the project container and `deco shell` opens an
  interactive shell, starting a compatible stopped container first.
- `deco stop` stops the project container, and `deco remove` removes the
  container and its image, retaining an image that other containers still use.
- Ownership labels on every resource: Deco never changes a container or image
  it did not create for this project.
- `-d`/`--dry-run` previews for every command that changes resources.
- Documented but not-yet-implemented settings are accepted, type-checked and
  ignored, and `deco validate` lists them.
- Signed source archives and a Linux x86_64 binary for each release.

[Unreleased]: https://github.com/Eccl3s/deco/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Eccl3s/deco/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Eccl3s/deco/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Eccl3s/deco/releases/tag/v0.1.0
