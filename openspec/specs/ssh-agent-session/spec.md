# ssh-agent-session Specification

## Purpose

SSH agent lifecycle for assets git push: configured identity, offer check before unlock, passphrase prompt, reuse, and owned-agent teardown.

## Requirements

### Requirement: Assets push unlocks only ssh-identity

When `update` will attempt an assets-repository `git push`, the program SHALL unlock only the private key named by config key `ssh-identity`. That value SHALL be one path. After a leading `~` expands to the operator's home, the path SHALL be absolute, SHALL name an existing file, and SHALL NOT end in `.pub`. Any other value SHALL hard-fail before a passphrase prompt. An omitted or empty value SHALL name `ssh-identity` in the error. A non-empty path SHALL appear in the error.

#### Scenario: Tilde path is the only key added

- **WHEN** an assets push will run and `ssh-identity` is `~/.ssh/keys/shanty_github_id` and that file exists under the operator's home
- **THEN** the program expands the leading `~` and passes only that absolute path to `ssh-add` when it must unlock a key

#### Scenario: Relative path fails before a prompt

- **WHEN** an assets push will run and `ssh-identity` is `keys/github`
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error includes `keys/github`

#### Scenario: Public-key path fails before a prompt

- **WHEN** an assets push will run and `ssh-identity` names an existing file that ends in `.pub`
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error includes that path

#### Scenario: Omitted key fails only when a push will run

- **WHEN** an assets push will run and the config omits `ssh-identity`
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error names `ssh-identity`

### Requirement: Omitted ssh-identity is valid without an assets push

A command that will not `git push` the assets repository SHALL load a config that omits `ssh-identity`. It SHALL NOT prompt for an SSH passphrase because that key is omitted.

#### Scenario: List loads without ssh-identity

- **WHEN** the operator runs `list` and the config omits `ssh-identity`
- **THEN** the command loads the config and does not prompt for an SSH passphrase

#### Scenario: Update without an assets push does not prompt

- **WHEN** the operator runs `update` for packages that will not `git push` the assets repository and the config omits `ssh-identity`
- **THEN** the program does not prompt for an SSH passphrase and does not start an `ssh-agent`

### Requirement: Early SSH readiness for the configured key

When `update` will attempt at least one assets-repository `git push`, the program SHALL make the configured private key available before parallel package work. When a reachable agent already has that key loaded, the program SHALL reuse it with no prompt and no `ssh-add`, and SHALL leave the inherited agent socket unchanged. Otherwise the program SHALL start an `ssh-agent`, add only that key, and this process's children SHALL inherit that socket, including assets `git push`.

#### Scenario: Spawn agent when none usable

- **WHEN** an assets push will run and no reachable agent has the configured key loaded
- **THEN** the program starts an `ssh-agent`, adds only that key, and children of this process inherit that socket before package parallel work

#### Scenario: Reuse when the configured key is loaded

- **WHEN** an assets push will run and a reachable agent already has the configured key loaded
- **THEN** the program does not prompt, does not run `ssh-add`, does not replace that agent, and does not kill it on exit

#### Scenario: Other loaded identities do not count

- **WHEN** an assets push will run and a reachable agent has identities loaded, none of which is the configured key
- **THEN** the program does not add a key to that agent
- **AND** it starts an agent, adds only the configured key, and leaves the original agent running

#### Scenario: Empty existing agent is not the add target

- **WHEN** an assets push will run and a reachable agent has no identities
- **THEN** the program does not run `ssh-add` against that agent
- **AND** it starts an agent and adds only the configured key

#### Scenario: Stale SSH_AUTH_SOCK falls back to new agent

- **WHEN** `SSH_AUTH_SOCK` is set but the agent is unreachable and an assets push will run
- **THEN** the program starts a new `ssh-agent` and adds only the configured key

#### Scenario: Add that does not load the key fails closed

- **WHEN** the program starts an agent and `ssh-add` of the configured key finishes without that key loaded
- **THEN** the program hard-fails and terminates the agent it started

### Requirement: Passphrase prompting via TTY or askpass

When `ssh-add` must unlock the configured private key, the program SHALL prefer prompting on the controlling terminal by attaching `ssh-add` to `/dev/tty` when available. When `/dev/tty` cannot be used, the program SHALL attempt `SSH_ASKPASS` (respecting an existing `SSH_ASKPASS` environment variable when set, otherwise a well-known helper such as `ksshaskpass` / `ssh-askpass` when present) and SHALL set `SSH_ASKPASS_REQUIRE=force` so a graphical or helper prompt can appear even without a TTY. Failure to prompt and load the key SHALL produce an error that names the key path and the prompt mode used (`tty` or `askpass`).

#### Scenario: Prompt on controlling terminal

- **WHEN** `/dev/tty` is available and the configured key must be unlocked
- **THEN** the program runs `ssh-add` with stdin attached to `/dev/tty` for that key only

#### Scenario: Askpass fallback without TTY

- **WHEN** `/dev/tty` is not usable, a suitable askpass helper is available, and the configured key must be unlocked
- **THEN** the program runs `ssh-add` with `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=force` for that key only

### Requirement: Owned SSH agent dies if the process is killed

When the program starts an `ssh-agent` for an assets push, a parent-death supervisor SHALL be running before the passphrase prompt. If the supervisor cannot start, the program SHALL hard-fail before the prompt and SHALL terminate that agent. If this process is killed after the agent has started, that agent SHALL still be terminated. The supervisor SHALL NOT terminate an agent the program reused.

#### Scenario: Supervisor failure blocks the prompt

- **WHEN** an assets push will run, the configured key is not already loaded, and the parent-death supervisor cannot start
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the agent it started is not left running

#### Scenario: Killed process does not leave the owned agent

- **WHEN** the program has started an `ssh-agent` and loaded the configured key, and the process is then killed
- **THEN** that agent is terminated

#### Scenario: Reused agent survives the supervisor

- **WHEN** the program reused an agent that already had the configured key loaded, and the process then exits
- **THEN** that agent is still running

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

Assets `git push` SHALL use the assets worktree’s existing `origin` (or configured) remote URL without rewriting SSH remotes to HTTPS token URLs.

#### Scenario: SSH remote left intact

- **WHEN** the assets worktree `origin` is an SSH URL
- **THEN** push uses that remote and does not convert it to an HTTPS URL embedding the GitHub token

### Requirement: SSH github push queries offered identities before unlock

When `update` will `git push` assets over SSH to host `github.com`, and git's SSH command is not overridden, the program SHALL run `ssh -G` for the identity files that connection will offer. The query SHALL NOT open a connection. It SHALL pass the URL's user when the URL names one, and SHALL finish before a passphrase prompt and before an `ssh-agent` starts. An `update` that will not push SHALL NOT run it.

#### Scenario: SCP-style URL queries as user git

- **WHEN** an assets push will run and the push URL is `git@github.com:alice/overlay-assets.git`
- **THEN** the program runs `ssh -G` for host `github.com` as user `git`
- **AND** it does not open a connection to `github.com`

#### Scenario: URL without a user omits the SSH user

- **WHEN** an assets push will run and the push URL is `ssh://github.com/alice/overlay-assets.git`
- **THEN** the program runs `ssh -G` for host `github.com` without an SSH user argument

#### Scenario: Update without an assets push does not query

- **WHEN** the operator runs `update` only for packages that will not `git push` the assets repository
- **THEN** the program does not run `ssh -G`

### Requirement: IdentitiesOnly mismatch fails before a prompt

When the query reports `IdentitiesOnly yes` and no offered identity file shares the SHA256 fingerprint of `ssh-identity`, the program SHALL hard-fail before a passphrase prompt and SHALL NOT start an `ssh-agent`. The error SHALL include the `ssh-identity` path and each offered path. A leading `~` SHALL expand to the operator home before fingerprinting. Any one matching offered file SHALL pass.

#### Scenario: Hostel key is not the GitHub identity file

- **WHEN** an assets push will run over SSH to `github.com` and `IdentitiesOnly` is `yes`
- **AND** `ssh-identity` is `/home/mndz/.ssh/keys/shanty_id_ed25519`
- **AND** the only offered identity file is `~/.ssh/keys/shanty_github_id`
- **AND** those two files have different SHA256 fingerprints
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error includes both paths
- **AND** the program does not start an `ssh-agent`

#### Scenario: Tilde path with the same fingerprint passes

- **WHEN** an assets push will run over SSH to `github.com` and `IdentitiesOnly` is `yes`
- **AND** `ssh-identity` is `/home/mndz/.ssh/keys/shanty_github_id`
- **AND** an offered identity file is `~/.ssh/keys/shanty_github_id`
- **AND** both paths have the same SHA256 fingerprint
- **THEN** the offer check passes and unlock of `ssh-identity` may continue

#### Scenario: Any one of several identity files may match

- **WHEN** an assets push will run over SSH to `github.com` and `IdentitiesOnly` is `yes`
- **AND** two identity files are offered and exactly one has the same SHA256 fingerprint as `ssh-identity`
- **THEN** the offer check passes

### Requirement: Unrestricted identities do not fail the offer check

When the query does not report `IdentitiesOnly yes`, the program SHALL NOT fail this check because `ssh-identity` differs from an offered identity file. Unlock then follows the configured-key readiness rules.

#### Scenario: Different identity file with IdentitiesOnly off

- **WHEN** an assets push will run over SSH to `github.com`
- **AND** the query does not report `IdentitiesOnly yes`
- **AND** the offered identity file and `ssh-identity` have different SHA256 fingerprints
- **THEN** the offer check passes

### Requirement: Web push URL skips the offer check

When the assets `origin` push URL uses `http` or `https`, the program SHALL NOT query offered identities for that push.

#### Scenario: HTTPS origin push URL

- **WHEN** an assets push will run and the push URL is `https://github.com/alice/overlay-assets.git`
- **THEN** the program does not run `ssh -G` for the offer check

### Requirement: Overridden SSH client fails before a prompt

When the assets `origin` push URL is SSH and `GIT_SSH_COMMAND` is set, or that worktree's effective `core.sshCommand` is non-empty, the program SHALL hard-fail before a passphrase prompt and SHALL NOT start an `ssh-agent`. The error SHALL name `GIT_SSH_COMMAND` or `core.sshCommand` and SHALL NOT include the command text.

#### Scenario: Environment override

- **WHEN** an assets push will run over SSH and `GIT_SSH_COMMAND` is set
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error names `GIT_SSH_COMMAND`
- **AND** the program does not start an `ssh-agent`

#### Scenario: Repository sshCommand override

- **WHEN** an assets push will run over SSH and the assets worktree's effective `core.sshCommand` is non-empty
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error names `core.sshCommand`

#### Scenario: Web push URL ignores an SSH command override

- **WHEN** an assets push will run and the push URL is `https://github.com/alice/overlay-assets.git`
- **AND** `GIT_SSH_COMMAND` is set
- **THEN** the program does not fail this check because `GIT_SSH_COMMAND` is set

### Requirement: Non-github SSH push URL fails before a prompt

When the assets `origin` push URL is SSH and its host is not `github.com`, the program SHALL hard-fail before a passphrase prompt and SHALL NOT start an `ssh-agent`. The error SHALL include that URL.

#### Scenario: SSH host is not github.com

- **WHEN** an assets push will run and the push URL is `git@git.example:alice/overlay-assets.git`
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error includes `git@git.example:alice/overlay-assets.git`
- **AND** the program does not start an `ssh-agent`

### Requirement: Unreadable offer data fails before a prompt

When `ssh -G` fails, the program SHALL hard-fail before a passphrase prompt and SHALL NOT start an `ssh-agent`. The error SHALL include the query failure. An offered identity path that cannot be fingerprinted SHALL NOT count as a match. A leading `~user` form SHALL NOT count as a match. When `IdentitiesOnly yes` and no offered path produces a matching fingerprint, the program SHALL hard-fail before a passphrase prompt. That error SHALL include the fingerprint failure when one was read.

#### Scenario: ssh -G fails

- **WHEN** an assets push will run over SSH to `github.com` and `ssh -G` exits non-zero
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the program does not start an `ssh-agent`

#### Scenario: Offered path cannot be fingerprinted

- **WHEN** an assets push will run over SSH to `github.com` and `IdentitiesOnly` is `yes`
- **AND** the only offered identity path cannot be fingerprinted
- **THEN** the program hard-fails before a passphrase prompt
- **AND** the error includes that path
