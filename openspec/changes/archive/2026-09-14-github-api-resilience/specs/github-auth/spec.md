## MODIFIED Requirements

### Requirement: GitHub token resolution order

The program SHALL resolve a GitHub API token by checking, in order: (1) environment variable `GITHUB_TOKEN` if set and non-empty; (2) environment variable `GH_TOKEN` if set and non-empty; (3) optional TOML config key `github-token` when it is a valid `mndz1.` envelope, after successful decrypt with the operator wrap password. The first non-empty resolved secret wins. The program SHALL NOT log the raw token value, the wrap password, or decrypted ciphertext.

When (1) or (2) wins, the program SHALL log a warning that an environment token is used instead of an encrypted config token, and SHALL log an additional warning if that environment value does not start with `github_pat_`. The program SHALL NOT probe environment tokens against GitHub solely for these warnings. Environment values are not required to be fine-grained PATs.

When (3) is the winner, the program SHALL prompt for the wrap password on a controlling TTY when this run will call `api.github.com` (version fetch, tag listing, assets-repository release lookup, download, create, or upload, or `/rate_limit` health). The program SHALL pause interactive activity indicators during that prompt, matching other TTY unlocks, and SHALL keep the decrypted token for the process lifetime of that run. The program SHALL NOT decrypt the envelope when this run will not call `api.github.com` (valid check-cache hits for every selected GitHub source and no assets GitHub work). If decrypt is required and no controlling TTY is available, the program SHALL hard-fail with an error that does not include a secret; it SHALL NOT silently fall back to unauthenticated GitHub fetch. Unattended runs SHALL use environment tokens instead of decrypt.

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

- **WHEN** neither `GITHUB_TOKEN` nor `GH_TOKEN` is set, config defines a `mndz1.` `github-token`, and a command will call `api.github.com`
- **THEN** the program prompts for the wrap password on a controlling TTY
- **AND** GitHub API calls use the decrypted config token

#### Scenario: Outdated decrypts when live GitHub fetch is needed

- **WHEN** the operator runs `outdated` with no env token, an encrypted `github-token` in config, and at least one selected GitHub-source package will live-fetch
- **THEN** the program prompts for the wrap password on a controlling TTY
- **AND** version fetch uses the decrypted token

#### Scenario: Outdated does not decrypt config envelope

- **WHEN** the operator runs `outdated` with no env token, an encrypted `github-token` in config, without `--refresh`, and every selected GitHub-source package has a valid check-cache hit
- **THEN** the program does not prompt for the wrap password
- **AND** it does not call `api.github.com` solely to decrypt or health-check

#### Scenario: Missing token when release required

- **WHEN** a selected package requires creating a GitHub release and no token is resolved (no env, no decryptable config envelope)
- **THEN** the program fails that requirement with an error that does not include a secret value (either at preflight or as a package hard-fail before publish)

#### Scenario: Decrypt without TTY hard-fails

- **WHEN** this run will call `api.github.com`, the winning token is the config envelope, and no controlling TTY is available
- **THEN** the program logs an error and exits with status `1` without logging a secret
- **AND** it does not proceed with unauthenticated GitHub fetch

### Requirement: Shared token for fetch and release

GitHub version fetch and GitHub Releases create/upload SHALL use the same resolved token when a token is available. Version fetch MAY proceed without a token (unauthenticated API) when no environment token and no config envelope are available, subject to `github-api-resilience` rate-limit and health behavior; release create and asset upload SHALL require a resolved token. When a config envelope exists and decrypt is required, the program SHALL NOT use unauthenticated fetch as a fallback.

#### Scenario: Release requires token

- **WHEN** the program attempts to create an assets repository release
- **THEN** it uses the resolved token in the Authorization header and does not attempt unauthenticated release creation as success

#### Scenario: No configured token still allows unauthenticated fetch

- **WHEN** `outdated` will live-fetch GitHub versions and neither env nor config `github-token` is available
- **THEN** version fetch MAY proceed unauthenticated
- **AND** the unauthenticated-quota warning specified by `github-api-resilience` applies
