# ssh-agent-session Specification

## Purpose

SSH agent lifecycle for assets git push: key discovery, passphrase prompt, reuse and teardown.

## Requirements

### Requirement: Early SSH readiness for assets push

When `update` will attempt at least one assets-repository `git push`, the program SHALL ensure SSH authentication is available before parallel package work begins. The program SHALL:

1. Reuse an existing reachable `SSH_AUTH_SOCK` agent when it already has loaded identities.
2. If the existing agent is reachable but has no identities, load keys into that agent (see key discovery and passphrase prompting).
3. If no usable agent is available (missing or unreachable `SSH_AUTH_SOCK`), start a new `ssh-agent`, export `SSH_AUTH_SOCK` and `SSH_AGENT_PID` for child processes (including assets `git push`), load keys, and own teardown of that agent.

The program SHALL NOT require the operator to manually start `ssh-agent` for the normal assets-push path.

#### Scenario: Spawn agent when none usable

- **WHEN** assets push is required and no usable SSH agent is available
- **THEN** the program starts `ssh-agent`, exports its environment, and loads discovered private keys before package parallel work

#### Scenario: Reuse existing agent with identities

- **WHEN** assets push is required and an existing usable `SSH_AUTH_SOCK` already has identities
- **THEN** the program does not replace that agent and does not kill it on exit

#### Scenario: Empty existing agent loads keys

- **WHEN** assets push is required and an existing agent is reachable but has no identities
- **THEN** the program runs key loading against that agent without starting a second agent unless the existing agent is unreachable

#### Scenario: Stale SSH_AUTH_SOCK falls back to new agent

- **WHEN** `SSH_AUTH_SOCK` is set but the agent is unreachable
- **THEN** the program starts a new `ssh-agent` and loads keys into it

### Requirement: Discover private keys from SSH config and defaults

When loading keys into an agent, the program SHALL discover private key paths by:

1. Parsing `IdentityFile` entries from `~/.ssh/config` (expanding `~`), and
2. Including OpenSSH default identity basenames under `~/.ssh/` when those files exist (`id_rsa`, `id_ed25519`, and other standard defaults).

The program SHALL pass the discovered existing key paths explicitly to `ssh-add`. It SHALL NOT rely solely on bare `ssh-add` with no arguments (which only tries default basenames and fails silently when keys live only under custom paths such as `~/.ssh/keys/…`).

#### Scenario: IdentityFile under keys subdirectory

- **WHEN** `~/.ssh/config` contains `IdentityFile ~/.ssh/keys/shanty_github_id` and that file exists
- **THEN** key loading includes that path in the `ssh-add` argument list

#### Scenario: No discoverable keys

- **WHEN** no `IdentityFile` paths exist on disk and no default identity files exist
- **THEN** SSH setup fails with an error explaining that keys must be listed as `IdentityFile` and/or placed under default `~/.ssh/id_*` names

### Requirement: Passphrase prompting via TTY or askpass

When `ssh-add` must unlock passphrase-protected keys, the program SHALL prefer prompting on the controlling terminal by attaching `ssh-add` to `/dev/tty` when available. When `/dev/tty` cannot be used, the program SHALL attempt `SSH_ASKPASS` (respecting an existing `SSH_ASKPASS` environment variable when set, otherwise a well-known helper such as `ksshaskpass` / `ssh-askpass` when present) and SHALL set `SSH_ASKPASS_REQUIRE=force` so a graphical or helper prompt can appear even without a TTY. Failure to prompt and load keys SHALL produce an error that names the key paths and the prompt mode used (`tty` or `askpass`).

#### Scenario: Prompt on controlling terminal

- **WHEN** `/dev/tty` is available for passphrase entry
- **THEN** the program runs `ssh-add` with stdin attached to `/dev/tty` for the discovered keys

#### Scenario: Askpass fallback without TTY

- **WHEN** `/dev/tty` is not usable and a suitable askpass helper is available
- **THEN** the program runs `ssh-add` with `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=force` for the discovered keys

### Requirement: Kill only agent started by the program

If the program started an `ssh-agent` for the run, it SHALL terminate that agent on process exit (success or failure). It SHALL NOT terminate an SSH agent that was already running when the program started (reused sessions).

#### Scenario: Teardown owned agent

- **WHEN** the program spawned `ssh-agent` at startup for assets push
- **THEN** that agent is terminated when the program ends

#### Scenario: Reused agent not killed

- **WHEN** the program reused an existing agent that already had identities
- **THEN** process exit does not kill that agent

### Requirement: No SSH setup when assets push not needed

When no selected package will perform assets `git push` (for example only `GitMvAndManifest` packages), the program SHALL NOT require `ssh-add` or spawn an SSH agent for that run.

#### Scenario: Binary-only update skips ssh-add

- **WHEN** the user runs `update` only for packages that use `GitMvAndManifest`
- **THEN** the program does not spawn an SSH agent solely for assets push

### Requirement: Prefer configured git remote transport

Assets `git push` SHALL use the assets worktree’s existing `origin` (or configured) remote URL without rewriting SSH remotes to HTTPS token URLs as part of this change.

#### Scenario: SSH remote left intact

- **WHEN** the assets worktree `origin` is an SSH URL
- **THEN** push uses that remote and does not convert it to an HTTPS URL embedding the GitHub token
