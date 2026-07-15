# github-auth Specification

## Purpose

Resolve GitHub API tokens from environment and config for version fetch and release write.

## Requirements

### Requirement: GitHub token resolution order

The program SHALL resolve a GitHub API token by checking, in order: (1) environment variable `GITHUB_TOKEN` if set and non-empty; (2) environment variable `GH_TOKEN` if set and non-empty; (3) optional TOML config key `github-token` if set and non-empty. The first non-empty value wins. The program SHALL NOT log the raw token value.

#### Scenario: Environment overrides config

- **WHEN** `GITHUB_TOKEN` is set to a non-empty value and config also defines `github-token`
- **THEN** GitHub API calls use the environment token

#### Scenario: Config used when env absent

- **WHEN** neither `GITHUB_TOKEN` nor `GH_TOKEN` is set and config defines `github-token`
- **THEN** GitHub API calls use the config token

#### Scenario: Missing token when release required

- **WHEN** a selected package requires creating a GitHub release and no token is resolved
- **THEN** the program fails that requirement with an error that does not include a secret value (either at preflight or as a package hard-fail before publish)

### Requirement: Shared token for fetch and release

GitHub version fetch and GitHub Releases create/upload SHALL use the same resolved token when a token is available. Version fetch MAY proceed without a token (unauthenticated API) subject to existing rate-limit behavior; release create and asset upload SHALL require a resolved token.

#### Scenario: Release requires token

- **WHEN** the program attempts to create an assets repository release
- **THEN** it uses the resolved token in the Authorization header and does not attempt unauthenticated release creation as success

### Requirement: Optional github-token config key

The configuration schema SHALL accept an optional `github-token` string key. Absence of the key SHALL NOT fail config load for commands that do not need GitHub write access.

#### Scenario: Config without token loads

- **WHEN** the config file defines `mndz-overlay-path` but omits `github-token`
- **THEN** config load succeeds for commands that do not require a token
