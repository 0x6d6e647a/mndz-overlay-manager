## ADDED Requirements

### Requirement: Plaintext github-token on disk hard-fails

When a command loads the overlay-manager TOML and the optional `github-token` key is present and non-empty after stripping, the value SHALL be a `mndz1.` ciphertext envelope. Any other present value (including a live `github_pat_`, `ghp_`, `gho_`, or other secret) SHALL be a config-load error: error-level log that does not include the secret, exit status `1`, and the command SHALL NOT continue. This SHALL apply even when `GITHUB_TOKEN` or `GH_TOKEN` is set. Whitespace-only or omitted `github-token` SHALL NOT fail config load by itself. Help-only paths SHALL NOT load the file and SHALL NOT emit this error.

#### Scenario: Plaintext PAT in config hard-fails list

- **WHEN** the operator runs `list` and `github-token` is a `github_pat_` or `ghp_` string
- **THEN** the program logs an error that the on-disk token is not encrypted
- **AND** the program exits with status `1`
- **AND** the log does not contain the token value

#### Scenario: Env does not excuse plaintext on disk

- **WHEN** `GITHUB_TOKEN` is set and the config `github-token` is plaintext
- **THEN** the program still hard-fails config load with exit `1`

#### Scenario: Envelope loads without decrypt

- **WHEN** `github-token` starts with `mndz1.` and the operator runs `list`
- **THEN** config load succeeds
- **AND** the program does not prompt for a wrap password

## MODIFIED Requirements

### Requirement: GitHub token resolution order

The program SHALL resolve a GitHub API token by checking, in order: (1) environment variable `GITHUB_TOKEN` if set and non-empty; (2) environment variable `GH_TOKEN` if set and non-empty; (3) optional TOML config key `github-token` when it is a valid `mndz1.` envelope, after successful decrypt with the operator wrap password. The first non-empty resolved secret wins. The program SHALL NOT log the raw token value, the wrap password, or decrypted ciphertext.

When (1) or (2) wins, the program SHALL log a warning that an environment token is used instead of an encrypted config token, and SHALL log an additional warning if that environment value does not start with `github_pat_`. The program SHALL NOT probe environment tokens against GitHub solely for these warnings. Environment values are not required to be fine-grained PATs.

When (3) is the winner, the program SHALL prompt for the wrap password on a controlling TTY only when a config token is actually required (creating or uploading GitHub releases, looking up or downloading assets-repo release assets, or other GitHub write/authenticated assets-repo operations that require the resolved token). `outdated` and other commands that MAY call GitHub without a token SHALL NOT decrypt a config envelope solely for optional authenticated fetch. If decrypt is required and no controlling TTY is available, the program SHALL hard-fail with an error that does not include a secret. Unattended runs SHALL use environment tokens instead of decrypt.

#### Scenario: Environment overrides config

- **WHEN** `GITHUB_TOKEN` is set to a non-empty value and config also defines an encrypted `github-token`
- **THEN** GitHub API calls use the environment token
- **AND** the program logs a warning that an environment token is used
- **AND** the program does not prompt for the wrap password

#### Scenario: Env non-PAT extra warning

- **WHEN** `GITHUB_TOKEN` is set to a `ghp_` value and a command resolves a token
- **THEN** the program logs the environment-token warning
- **AND** the program logs an additional warning that the environment token is not a fine-grained PAT
- **AND** GitHub API calls still use the environment token

#### Scenario: Config used when env absent

- **WHEN** neither `GITHUB_TOKEN` nor `GH_TOKEN` is set, config defines a `mndz1.` `github-token`, and a command requires a token for assets publish
- **THEN** the program prompts for the wrap password on a controlling TTY
- **AND** GitHub API calls use the decrypted config token

#### Scenario: Outdated does not decrypt config envelope

- **WHEN** the operator runs `outdated` with no env token and an encrypted `github-token` in config
- **THEN** the program does not prompt for the wrap password
- **AND** version fetch MAY proceed unauthenticated

#### Scenario: Missing token when release required

- **WHEN** a selected package requires creating a GitHub release and no token is resolved (no env, no decryptable config envelope)
- **THEN** the program fails that requirement with an error that does not include a secret value (either at preflight or as a package hard-fail before publish)

#### Scenario: Decrypt without TTY hard-fails

- **WHEN** assets publish requires the config envelope token and no controlling TTY is available
- **THEN** the program logs an error and exits with status `1` without logging a secret

### Requirement: Optional github-token config key

The configuration schema SHALL accept an optional `github-token` string key. Absence of the key SHALL NOT fail config load for commands that do not need GitHub write access. When the key is present and non-empty, its value SHALL be a `mndz1.` envelope as specified by the plaintext-on-disk hard-fail requirement; the program SHALL NOT treat a live PAT string as a usable config token.

#### Scenario: Config without token loads

- **WHEN** the config file defines `overlay-path` but omits `github-token`
- **THEN** config load succeeds and the token is resolved from the environment if present
