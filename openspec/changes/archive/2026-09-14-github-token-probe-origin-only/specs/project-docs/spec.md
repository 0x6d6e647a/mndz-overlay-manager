## MODIFIED Requirements

### Requirement: README documents encrypted github-token and derived assets repo

Operator-facing `README.md` SHALL document:

1. Work command `github-token` (interactive store, `--force` to replace).
2. That `github-token` in the TOML is a `mndz1.` ciphertext envelope, not a live PAT, and that a plaintext value hard-fails every command that loads config until the operator runs `github-token --force`.
3. That the persisted token MUST be a fine-grained PAT (`github_pat_`) limited to the assets GitHub repository with Contents: write (Metadata: read comes with that grant).
4. That GitHub always includes read-only access to public repositories on a fine-grained PAT, so `github-token` SHALL still accept a PAT when the operator owns other public repositories. Only-select repositories is operator guidance; the setter does not fail the probe because other owned repositories exist.
5. Token resolution order: `GITHUB_TOKEN`, then `GH_TOKEN`, then decrypted config envelope; environment use logs a warning (and an extra warning when the env value is not `github_pat_`).
6. That GitHub Releases and assets `SRC_URI` use `{owner}/{repo}` from `assets-path` `origin` on `github.com`, not a hardcoded GitHub owner or repository name.

#### Scenario: README names github-token command

- **WHEN** an operator reads `README.md` for configuration and work commands
- **THEN** the file documents `github-token`, `--force`, encrypted `github-token` in the TOML, and the fine-grained PAT requirement

#### Scenario: README names origin-derived assets repo

- **WHEN** an operator reads how assets releases are published
- **THEN** README states that the GitHub repository is taken from `assets-path` `origin`

#### Scenario: README names public-repo read vs setter probe

- **WHEN** an operator reads how to create the GitHub PAT for `github-token`
- **THEN** README states that GitHub’s always-on public-repository read does not fail the setter, and that Only-select plus Contents: write on the assets origin is operator guidance rather than an extra-repository API check
