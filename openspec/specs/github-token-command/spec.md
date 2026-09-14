# github-token-command Specification

## Purpose

Interactive `github-token` work command that probes a fine-grained GitHub PAT, wraps it with a password, and writes ciphertext into the overlay-manager TOML without putting secrets on the command line.

## Requirements

### Requirement: github-token command stores an encrypted PAT

The program SHALL provide a work subcommand `github-token` that:

1. Loads the overlay-manager TOML (from `--config` if supplied, otherwise the XDG default) without overlay validation (`profiles/repo_name` and layout checks SHALL NOT run).
2. Requires `assets-path` to name a git work tree whose `origin` remote URL parses as `github.com/{owner}/{repo}` (SSH or HTTPS, optional `.git` suffix). Other hosts SHALL hard-fail.
3. Requires a controlling terminal. The program SHALL NOT accept the GitHub token or wrap password from argv flags.
4. Prompts on that TTY (no echo) for a GitHub token, then probes GitHub with that token, then prompts for a wrapping password and a confirmation. Probe failure SHALL hard-fail before the password prompts.
5. On success, encrypts the token into a `mndz1.` envelope and writes it to the `github-token` key, preserving other keys and comments, keeping file mode `0600`. Successful write SHALL log or print the config path only (no token, no password, no last-four).

If `github-token` is already present (plaintext or envelope), the command SHALL hard-fail unless `--force` is supplied. `--force` still runs prefix checks and the probe; it only allows replacing the existing key. Help-only `github-token --help` / `-h` SHALL NOT load configuration.

#### Scenario: First store writes envelope

- **WHEN** the operator runs `github-token`, the config omits `github-token`, TTY prompts succeed, and the probe succeeds
- **THEN** the config file contains a `github-token` value that starts with `mndz1.`
- **AND** the file mode remains `0600`
- **AND** output names the config path and does not include the PAT or wrap password

#### Scenario: Existing key requires force

- **WHEN** the operator runs `github-token` without `--force` and the config already defines `github-token`
- **THEN** the program logs an error and exits with status `1` without rewriting the file

#### Scenario: Force replaces after probe

- **WHEN** the operator runs `github-token --force`, TTY prompts succeed, and the probe succeeds
- **THEN** the `github-token` key is replaced with a new `mndz1.` envelope

#### Scenario: Help skips config

- **WHEN** the operator runs `github-token --help`
- **THEN** the program writes command-scoped help and exits `0` without loading configuration

#### Scenario: Missing assets-path hard-fails

- **WHEN** the operator runs `github-token` and the config omits `assets-path`
- **THEN** the program logs an error naming `assets-path` and exits with status `1`

#### Scenario: Non-github origin hard-fails

- **WHEN** `assets-path` `origin` is not a `github.com` owner/repo URL
- **THEN** the program logs an error and exits with status `1` without writing a token

#### Scenario: No TTY hard-fails

- **WHEN** the operator runs `github-token` without a controlling terminal
- **THEN** the program logs an error and exits with status `1` without reading secrets from argv

### Requirement: Setter accepts only fine-grained PATs and probes the assets repo

The GitHub token pasted into `github-token` SHALL start with `github_pat_`. Other prefixes (`ghp_`, `gho_`, `ghs_`, `ghu_`, `ghr_`, or anything else) SHALL hard-fail before the wrap-password prompts.

The program SHALL probe, fail-closed (no config write), using the `{owner}/{repo}` parsed from `assets-path` `origin`:

1. `GET /repos/{owner}/{repo}` succeeds (HTTP 2xx).
2. `POST /repos/{owner}/{repo}/releases` with an empty JSON object returns HTTP 422 (validation failed; no release created). HTTP 403 SHALL be treated as missing Contents: write.

The program SHALL NOT fail the probe because the token can list or appear to write other owned repositories (including GitHub’s always-on public-repository read). Extra owned repository names SHALL NOT be a probe failure.

Network or unexpected HTTP failures SHALL hard-fail without writing. The program SHALL NOT log the token.

#### Scenario: Classic PAT refused

- **WHEN** the operator pastes a token starting with `ghp_`
- **THEN** the program logs an error that a fine-grained PAT (`github_pat_`) is required
- **AND** the program does not prompt for a wrap password
- **AND** the config file is not modified

#### Scenario: Probe requires Contents write via 422

- **WHEN** empty `POST /releases` on the assets origin returns HTTP 403
- **THEN** the program hard-fails without writing `github-token`

#### Scenario: Extra owned repos refused

- **WHEN** the operator owns repositories other than the assets origin
- **AND** `GET /repos/{owner}/{repo}` for the origin succeeds
- **AND** empty `POST /releases` on the assets origin returns HTTP 422
- **THEN** the probe succeeds (the program may continue to wrap-password prompts)

#### Scenario: Assets repo GET 404 refused

- **WHEN** `GET /repos/{owner}/{repo}` for the origin repo is not successful
- **THEN** the program hard-fails without writing `github-token`
