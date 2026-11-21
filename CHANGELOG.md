# Changelog

All notable changes to Deco are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Deco follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, minor
releases may change behaviour.

## [Unreleased]

### Changed

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

[Unreleased]: https://github.com/Eccl3s/deco/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Eccl3s/deco/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Eccl3s/deco/releases/tag/v0.1.0
