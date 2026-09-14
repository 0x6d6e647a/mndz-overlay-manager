## RENAMED Requirements

- FROM: `### Requirement: Update decrypts config token only when assets GitHub needs it`
- TO: `### Requirement: Update decrypts config token when this run will call GitHub`

## MODIFIED Requirements

### Requirement: Update decrypts config token when this run will call GitHub

When `update` will call `api.github.com` this run (live latest-version fetch or runtime-lane plan for a GitHub update source, `/rate_limit` health, or assets-repository release lookup, download, create, or upload) and the winning token source is the encrypted config `github-token` envelope, the program SHALL prompt for the wrap password on a controlling TTY before those GitHub operations and SHALL keep the decrypted token for the process lifetime of that run. The program SHALL pause interactive activity indicators during that prompt, matching other TTY unlocks. When an environment token wins, `update` SHALL NOT prompt. When this run will not call `api.github.com`, `update` SHALL NOT decrypt the config envelope.

GitHub health, rate-limit class, and token-rejected failures specified by `github-api-resilience` SHALL abort `update` with exit status `1` (plan or mutate) and SHALL NOT continue remaining GitHub plan or apply work. Git Operations Statuspage checks SHALL run only when this run will `git push` assets, as specified by `github-api-resilience`.

#### Scenario: Assets publish prompts once

- **WHEN** `update` will publish at least one assets release, no env token is set, and config has a `mndz1.` envelope
- **THEN** the program prompts for the wrap password on a controlling TTY before release create
- **AND** it does not prompt again solely to publish a later package in the same run

#### Scenario: Live GitMv plan decrypts

- **WHEN** `update` selects only `GitMvAndManifest` packages, at least one needs a live GitHub latest fetch, no env token is set, and config has a `mndz1.` envelope
- **THEN** the program prompts for the wrap password before that fetch

#### Scenario: GitMv-only update skips decrypt

- **WHEN** `update` selects only `GitMvAndManifest` packages, every selected GitHub latest payload is a valid check-cache hit, `--refresh` was not passed, and no assets GitHub access is required
- **THEN** the program does not prompt for the wrap password
