# Spec Delta

## ADDED Requirements

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
