## MODIFIED Requirements

### Requirement: Setter accepts only fine-grained PATs and probes the assets repo

The GitHub token pasted into `github-token` SHALL start with `github_pat_`. Other prefixes (`ghp_`, `gho_`, `ghs_`, `ghu_`, `ghr_`, or anything else) SHALL hard-fail before the wrap-password prompts.

The program SHALL probe, fail-closed (no config write), using the `{owner}/{repo}` parsed from `assets-path` `origin`:

1. `GET /repos/{owner}/{repo}` succeeds (HTTP 2xx).
2. Paginated `GET /user/repos?affiliation=owner` is fetched. Extra listed repositories SHALL NOT fail the probe when the token does not have Contents: write on them (including GitHub’s always-on public-repository read). The program SHALL hard-fail when the token has Contents: write on any listed repository other than `{owner}/{repo}`.
3. `POST /repos/{owner}/{repo}/releases` with an empty JSON object returns HTTP 422 (validation failed; no release created). HTTP 403 SHALL be treated as missing Contents: write.

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

- **WHEN** `GET /user/repos?affiliation=owner` lists the assets origin and another repository on which the token has Contents: write
- **THEN** the program hard-fails without writing `github-token`

#### Scenario: Public-read extra owned repos accepted

- **WHEN** `GET /user/repos?affiliation=owner` lists the assets origin and other owned repositories on which the token does not have Contents: write
- **AND** `GET /repos/{owner}/{repo}` succeeds
- **AND** empty `POST /releases` on the assets origin returns HTTP 422
- **THEN** the probe succeeds (the program may continue to wrap-password prompts)

#### Scenario: Assets repo GET 404 refused

- **WHEN** `GET /repos/{owner}/{repo}` for the origin repo is not successful
- **THEN** the program hard-fails without writing `github-token`
