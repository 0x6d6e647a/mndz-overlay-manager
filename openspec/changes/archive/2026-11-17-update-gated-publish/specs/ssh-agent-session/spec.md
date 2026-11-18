# Spec Delta

## MODIFIED Requirements

### Requirement: Assets push unlocks only ssh-identity

When `update` will attempt an assets-repository `git push`, an overlay `git push`, or the sync fetch of either repository, the program SHALL unlock only the private key named by config key `ssh-identity`. That value SHALL be one path. After a leading `~` expands to the operator's home, the path SHALL be absolute, SHALL name an existing file, and SHALL NOT end in `.pub`. Any other value SHALL hard-fail before a passphrase prompt. An omitted or empty value SHALL name `ssh-identity` in the error. A non-empty path SHALL appear in the error.

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

#### Scenario: Overlay push uses the same key

- **WHEN** only `GitMvAndManifest` packages need work, so only the overlay will be fetched and pushed
- **THEN** the program unlocks only the key named by `ssh-identity`

### Requirement: Omitted ssh-identity is valid without an assets push

A command that will not `git push` or sync-fetch the assets repository or the overlay SHALL load a config that omits `ssh-identity`. It SHALL NOT prompt for an SSH passphrase because that key is omitted.

#### Scenario: List loads without ssh-identity

- **WHEN** the operator runs `list` and the config omits `ssh-identity`
- **THEN** the command loads the config and does not prompt for an SSH passphrase

#### Scenario: Update without an assets push does not prompt

- **WHEN** the operator runs `update`, no selected package needs work, and the config omits `ssh-identity`
- **THEN** the program does not prompt for an SSH passphrase and does not start an `ssh-agent`

### Requirement: No SSH setup when assets push not needed

When no unit needs work in an `update` run, so no assets or overlay `git push` or sync fetch will happen, the program SHALL NOT require `ssh-add` or spawn an SSH agent for that run.

#### Scenario: Binary-only update skips ssh-add

- **WHEN** the user runs `update` only for packages that use `GitMvAndManifest` and none of them needs work
- **THEN** the program does not spawn an SSH agent

#### Scenario: GitMv-only update sets up SSH

- **WHEN** the user runs `update` and only `GitMvAndManifest` packages need work
- **THEN** the program prepares SSH for the overlay fetch and push
