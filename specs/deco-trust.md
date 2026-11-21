# Deco Configuration Trust v1 Specification

## 1. Status and terminology

This document defines configuration trust for deco: how a user approves a
project's `.deco/` contents, how Deco records that approval, and which commands
refuse to act on configuration that has not been approved.

The key words **must**, **must not**, **required**, **should**, and **may** are
to be interpreted as requirements.

Command behavior is defined by [`deco-cli.md`](./deco-cli.md) and
configuration behavior by [`deco-config.md`](./deco-config.md). When those
documents and this one discuss the same operation, the requirements in all of
them apply.

Terms:

- **Project root**: the canonical absolute path of the directory containing
  `.deco/`, as determined by project discovery.
- **Trust digest**: a digest computed over the project's `.deco/` contents as
  defined in section 3.
- **Approval**: a recorded trust digest for a project root.
- **Trust store**: the per-user directory in which approvals are recorded.

## 2. Purpose and threat model

`.deco/config.toml` controls the isolation of the development container. It
can request privileged mode, host devices, added capabilities, host
namespaces, host networking, read-write bind mounts of host paths such as
`~/.ssh`, and host env files. `.deco/` also contains the Containerfile, whose
instructions run during image builds, and lifecycle hooks, which Deco runs
without further confirmation. Acting on an unreviewed `.deco/` directory is
therefore comparable to running unreviewed code on the host.

Trust ensures that Deco does not build, create, start, stop, remove, or run
hooks or commands for a configuration that the current host user has not
approved, except for the hook-free `stop` and `remove` described in
section 6. This includes `.deco/` contents that arrive by cloning a repository,
pulling changes, switching branches, or extracting an archive.

Trust is scoped to one host user and one project root. Approvals are
content-bound: any change to the trusted contents requires a new approval.
Moving or renaming the project root requires a new approval, consistent with
the `dev.deco.project-root` ownership label.

Trust is not a sandbox. It does not protect against, and must not be described
as protecting against:

- Project source code that approved hooks and actions execute. For example,
  an approved `post_create = "npm install"` runs scripts from `package.json`,
  which is outside `.deco/`.
- The contents of env files, of build-context files outside `.deco/`, or of the
  workspace.
- An attacker who can write to the user's trust store or to the project tree
  while Deco runs.
- Changes made between Deco's trust check and Podman reading a file, such as
  the Containerfile during a build.

## 3. Trust digest

### Inputs

The trust digest covers:

1. Every entry beneath the project's `.deco/` directory, walked recursively.
   If `.deco` is a symlink, Deco walks the directory it resolves to.
2. The project configuration file, when `.deco/config.toml` is a symlink
   whose canonical target is not inside the canonical `.deco/` directory.
3. The resolved `build.containerfile`, when its canonical path is not inside
   the canonical `.deco/` directory.

Each entry contributes one record:

| Entry type | Record contents |
| --- | --- |
| Directory | Its relative path. Empty directories are therefore covered. |
| Regular file | Its relative path and its complete content bytes. |
| Symbolic link | Its relative path and its link target, read without following the link. |

Relative paths are relative to `.deco/`, use `/` as the separator, and are
sorted byte-wise before digesting. The `.deco/` directory itself has no
record. A configuration file or Containerfile outside `.deco/` contributes a
regular-file record whose path is its canonical absolute path, in addition to
any symlink record beneath `.deco/` that leads to it. Absolute paths can never
equal a relative `.deco/` path, so the two kinds of record cannot be confused.
If the configuration file and the Containerfile resolve to the same path, it
contributes one record.

Any other entry type, such as a FIFO, socket, or device node, makes the trust
digest uncomputable. Deco must treat this as a configuration error, exit with
code `2`, and name the offending path.

The trust digest does not cover file modes, timestamps, or ownership. It also
does not cover the build context outside `.deco/`, env file contents, files
named by `[[mounts.volumes]]`, or the workspace.

### Encoding and algorithm

Records are serialized as an unambiguous, length-prefixed stream. Each record
consists of a one-byte type tag, the path length, the path bytes, and, for
files and symlinks, the content length and content bytes. Lengths are
fixed-width unsigned integers.

The digest algorithm is BLAKE2b with a 256-bit output. Deco writes a digest as
`blake2b-256:` followed by lowercase hexadecimal. The prefix identifies the
algorithm; a future release may introduce another algorithm under a different
prefix and treat approvals with an unknown prefix as not matching.

Deco also computes a per-entry digest of each record, so it can report which
entries changed since an approval (section 5).

### Consistency with what Deco uses

When a command both checks trust and parses `.deco/config.toml`, the bytes
Deco parses must be the bytes it digested. Deco must not read the file a
second time between the trust check and parsing. This applies to the
configuration file's regular-file record wherever it is, beneath `.deco/` or
outside it.

## 4. Trust store

Approvals are stored in:

```text
$XDG_STATE_HOME/deco/trust/
```

If `XDG_STATE_HOME` is unset, empty, or not an absolute path, Deco uses
`~/.local/state/deco/trust/`. Deco creates missing directories with mode
`0700` and must not write trust data into the project tree.

Each project root has at most one record file. Its name is the BLAKE2b-256 of
the canonical project-root path, in lowercase hexadecimal, followed by
`.json`. The file contains:

```json
{
  "version": 1,
  "project_root": "/home/user/my-project",
  "project_name": "my-project",
  "approved": [
    {
      "digest": "blake2b-256:4c1f…",
      "trusted_at": "2026-11-21T10:02:13Z",
      "deco_version": "0.3.0",
      "entries": {
        "build": "blake2b-256:…",
        "build/Containerfile": "blake2b-256:…",
        "config.toml": "blake2b-256:…"
      }
    }
  ]
}
```

- `approved` is ordered from most to least recent. Each approval records the
  trust digest, the approval time in UTC RFC 3339 format with second
  precision, the Deco version that recorded it, and the per-entry digests.
- Approving a digest that is already present moves it to the front.
- Deco keeps at most 16 approvals per project root and drops the oldest.
  Several approvals let a user switch back to an already-approved branch
  without approving it again.
- `project_name` is informational and is never used to match a record.

Deco writes record files atomically by writing a temporary file in the same
directory and renaming it. Record files are created with mode `0600`.

A record file that cannot be parsed, has an unsupported `version`, or whose
`project_root` does not hash to its file name is treated as absent. Deco
writes a warning naming the file to stderr and must not delete or rewrite it
except through `deco trust` or `deco trust --revoke`.

## 5. Trust states

For the current project root and trust digest, the trust state is:

| State | Meaning |
| --- | --- |
| `trusted` | The current trust digest equals the digest of an approval in the project's record. |
| `changed` | A record exists, but none of its approvals matches the current trust digest. |
| `untrusted` | No valid record exists for the project root. |

For `changed`, Deco reports the entries that differ from the most recent
approval, each marked as added, modified, or removed and sorted byte-wise by
path. Changed entry paths are escaped for terminal output as in `deco list`.

## 6. Commands that require trust

These commands require the `trusted` state:

```text
assemble  refresh  start  stop  remove  exec  shell  run
```

`stop` and `remove` require trust because they run `pre_stop`. Deco never
mutates Podman resources or runs hooks, actions, or commands for a
configuration that is not trusted, with the single exception described under
"Stopping and removing without hooks".

These commands do not require trust: `validate`, `info`, `list`, `actions`,
`completion`, `init`, and `trust`. A `--dry-run` of any command does not
require trust.

For a command that requires trust, the order is:

1. Discover the project. Named selection with `--project` may query Podman to
   locate the project root, as described in `deco-cli.md`.
2. Parse and validate the configuration. Invalid configuration fails with
   exit code `2` regardless of trust.
3. Compute the trust digest and determine the trust state.
4. If the state is not `trusted`, fail with exit code `5` before any further
   Podman operation, file write, or hook.

The failure message is written to stderr and must include the trust state,
the project root, the changed entries when the state is `changed`, and the
instruction to run `deco trust` to review and approve the configuration.

Example:

```text
deco: configuration for /home/user/my-project has changed since it was trusted
  modified  config.toml
  added     scripts/setup.sh
Run 'deco trust' to review and approve it.
```

When `stop` or `remove` fails for this reason, the message must also mention
`--no-hooks`.

### Stopping and removing without hooks

`stop` and `remove` accept `--no-hooks`, which skips `pre_stop`. With
`--no-hooks`, these commands do not require trust: they then run nothing taken
from the configuration and change only resources that pass the ownership
checks in `deco-cli.md`. This lets a user clean up a project whose
configuration they do not trust, and stop or remove a container whose
`pre_stop` hook fails or hangs.

- Deco still determines the trust state. When it is not `trusted`, Deco writes
  a warning to stderr stating the trust state and that `pre_stop` was
  skipped, then proceeds.
- `remove --force` stops and removes dependent containers that Deco may not
  have created, so it still requires trust. `remove --no-hooks --force` on
  configuration that is not trusted fails with exit code `5`.
- `--no-hooks` is accepted only by `stop` and `remove`. Skipping hooks does
  not make an untrusted configuration safe for commands that create, start,
  or run anything from it.

Commands that require trust must not prompt for approval. No environment
variable, CI detection, or configuration key grants trust automatically.
Non-interactive environments approve explicitly with `deco trust --yes`.
`.deco/config.toml` has no key that affects trust.

## 7. `deco trust`

```text
deco trust [--yes] [--dry-run]
deco trust --show
deco trust --revoke
```

Reviews and approves the current project's configuration. `trust` accepts
`--project` and `--project-dir`. Project discovery and validation run as for
any project command. Deco only records approval for a configuration that
passes validation, so invalid configuration fails with exit code `2`.

### Options

| Option | Description |
| --- | --- |
| `-y, --yes` | Approve without prompting. |
| `-d, --dry-run` | Print the review without prompting or recording an approval. |
| `--show` | Print the trust state without the review and without prompting. |
| `--revoke` | Remove every approval for the project root. |

`--show` and `--revoke` are mutually exclusive with each other and with
`--yes` and `--dry-run`. Combining them is a usage error with exit code `2`.

### Review and approval

Without `--show` or `--revoke`, Deco computes the trust digest and the trust
state.

If the state is already `trusted`, Deco prints
`Configuration is already trusted: <project root>`, records nothing, and exits
`0`.

Otherwise, Deco prints a review to stdout containing:

1. The project name, project root, and trust state.
2. For `changed`, the changed entries as defined in section 5.
3. A security summary of the resolved configuration:
   - `container.privileged`, `container.devices`, `container.cap_add`,
     `container.cap_drop`, and `container.security_options`;
   - every configured `[container.namespaces]` mode;
   - `network.mode`, flagging `host`;
   - every bind mount whose canonical source is outside the project root, with
     read-write mounts flagged;
   - `container.env_files` paths and `[[container.secrets]]` names, without
     their contents;
   - `user.mode`;
   - every hook and action command, in full;
   - the build context and Containerfile paths, flagging a build context
     outside `.deco/`.
4. The planned settings that Deco accepts but ignores, as listed by
   `deco validate`.

Values are escaped for terminal output as in `deco list`. Secret values and
environment-variable values must not be printed.

After the review:

- With `--dry-run`, Deco records nothing and exits `0`.
- With `--yes`, Deco records the approval.
- Otherwise, when stdin and stdout are both terminals, Deco asks
  `Trust this configuration? [y/N] `. An answer of `y` or `yes`, ignoring
  ASCII case and surrounding whitespace, records the approval. Any other
  answer, including end of input, records nothing, prints
  `Configuration not trusted.` to stderr, and exits `1`.
- Otherwise, Deco records nothing and fails with exit code `2`, telling the
  user to rerun in a terminal or to pass `--yes`.

Deco must compute the trust digest again immediately before recording the
approval. If it differs from the reviewed digest, Deco records nothing and
fails with exit code `1`, reporting that `.deco/` changed during review.

On approval, Deco prints `Trusted <project root>` and exits `0`. If the trust
store cannot be written, Deco fails with exit code `1`.

### `--show`

Prints the trust state, project root, current trust digest, the time of the
most recent approval or `-`, and the changed entries for `changed`. It never
prompts, records nothing, and exits `0` in every trust state.

### `--revoke`

Deletes the project root's record file and prints
`Trust revoked: <project root>`. When no record exists, it prints
`Configuration was not trusted: <project root>` and exits `0`. Revocation
does not change Podman resources.

## 8. Interaction with other commands

### `deco init`

After `init` writes its files successfully, it computes the trust digest of
the resulting `.deco/` directory, records an approval, and prints
`Trusted <project root>`. This applies with and without `--replace`. Because
the digest covers all of `.deco/`, an approval recorded by `init --replace`
also covers unrelated files already present in `.deco/`. Printing the trusted
root makes that visible.

`init --dry-run` records nothing. If the trust store cannot be written, `init`
leaves the written files in place, reports the problem on stderr, and exits
`1`.

### `deco info`

`info` reports the trust state without requiring it. JSON output gains this
object:

```json
"trust": {
  "state": "changed",
  "digest": "blake2b-256:4c1f…",
  "trusted_at": "2026-11-21T10:02:13Z",
  "changed": [
    { "path": "config.toml", "change": "modified" }
  ]
}
```

- `state` is `trusted`, `changed`, or `untrusted`.
- `digest` is the current trust digest.
- `trusted_at` is the time of the matching approval for `trusted`, the most
  recent approval for `changed`, and `null` for `untrusted`.
- `changed` lists entries as defined in section 5. Each `change` is `added`,
  `modified`, or `removed`. The array is empty unless `state` is `changed`.

Human output adds a trust section immediately after the project section.

If the trust state cannot be determined, for example because `.deco/` contains
an unsupported file type, `info` still writes the full report with `trust` set
to `null` and the human trust fields shown as `-`, reports the problem on
stderr, and exits `2`. This takes precedence over exit `3` for unavailable
Podman. An unusable trust record is not such a failure: the project is
reported as `untrusted` and the record is named in a warning on stderr.

### `deco validate`

`validate` does not require trust and its exit status does not depend on
trust. It may print the trust state as an informational line.

### Dry runs

A dry run of a command that requires trust performs the same trust check but
does not fail on it. When the state is not `trusted`, the dry run writes this
note to stderr and otherwise behaves normally:

```text
Note: configuration is not trusted; 'deco <command>' would fail with exit code 5.
```

## 9. Conformance scenarios

A conforming implementation must cover at least these scenarios:

1. A project with no record is `untrusted`, and `assemble` fails with exit
   code `5` without invoking any Podman command that mutates resources.
2. `deco trust --yes` makes the project `trusted`, and `assemble` proceeds.
3. Modifying, adding, or removing any entry beneath `.deco/`, including files
   other than `config.toml`, empty directories, and symlinks, makes the
   project `changed`, and each changed entry is reported.
4. Restoring `.deco/` to a previously approved state makes the project
   `trusted` again without a new approval.
5. A `build.containerfile` outside `.deco/` is covered by the trust digest.
6. Moving the project root makes the project `untrusted`.
7. `init` leaves the project `trusted`; `init --dry-run` records nothing.
8. Dry runs and commands that do not require trust succeed while the project
   is `untrusted` or `changed`.
9. Outside a terminal, `deco trust` without `--yes` exits `2`. Declining the
   prompt exits `1` and records nothing.
10. `--show` exits `0` in every state. `--revoke` removes every approval and
    is a successful no-op when none exists.
11. A malformed or mismatched record file is treated as `untrusted`, and a
    warning is written to stderr.
12. A FIFO, socket, or device node beneath `.deco/` fails with exit code `2`.
13. `stop --no-hooks` and `remove --no-hooks` succeed for configuration that
    is not trusted, skip `pre_stop`, and warn on stderr.
    `remove --no-hooks --force` for configuration that is not trusted fails
    with exit code `5`.
14. A `.deco/config.toml` symlink whose target is outside `.deco/` is covered
    by the target's contents, so editing the target makes the project
    `changed`.
