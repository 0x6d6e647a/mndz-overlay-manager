## ADDED Requirements

### Requirement: Update decrypts config token only when assets GitHub needs it

When `update` determines that at least one package that needs work requires a GitHub token for assets-repository release create, upload, lookup, or download, and the winning token source is the encrypted config `github-token` envelope, the program SHALL prompt for the wrap password on a controlling TTY before those GitHub operations and SHALL keep the decrypted token for the process lifetime of that run. The program SHALL pause interactive activity indicators during that prompt, matching other TTY unlocks. When an environment token wins, `update` SHALL NOT prompt. When no selected package that needs work requires that GitHub access, `update` SHALL NOT decrypt the config envelope.

#### Scenario: Assets publish prompts once

- **WHEN** `update` will publish at least one assets release, no env token is set, and config has a `mndz1.` envelope
- **THEN** the program prompts for the wrap password on a controlling TTY before release create
- **AND** it does not prompt again solely to publish a later package in the same run

#### Scenario: GitMv-only update skips decrypt

- **WHEN** `update` selects only packages that use `GitMvAndManifest` and none require assets GitHub access
- **THEN** the program does not prompt for the wrap password

### Requirement: Update requires parseable assets origin when assets GitHub is required

When `update` requires assets-path because a package that needs work will attempt `DepsAndAssets` apply, it SHALL parse `github.com/{owner}/{repo}` from that worktree’s `origin` as specified by `assets-publish`. Parse failure SHALL fail the spine with exit status `1` before package mutation, with an error that does not include a secret.

#### Scenario: Missing origin hard-fails before mutate

- **WHEN** `update` will attempt `DepsAndAssets` apply and `assets-path` has no `origin` remote
- **THEN** the program logs an error and exits with status `1` before package mutation
