## ADDED Requirements

### Requirement: Assets GitHub owner and repo come from origin

When the program talks to the GitHub Releases API for the assets worktree (create release, upload assets, delete a partial release, get release by tag, download a named asset), it SHALL use `{owner}` and `{repo}` parsed from that worktree’s `origin` remote URL. The URL SHALL be `github.com` over SSH or HTTPS (optional `.git` suffix). The program SHALL NOT hardcode a GitHub owner or repository name for those API calls. If `assets-path` is required and `origin` is missing, not `github.com`, or does not parse as `owner/repo`, the program SHALL hard-fail with an error that names the remote problem before mutating overlay or publishing releases.

#### Scenario: SSH origin selects the API repo

- **WHEN** `assets-path` `origin` is `git@github.com:alice/overlay-assets.git` and a package publishes a GitHub release
- **THEN** create/upload uses `alice/overlay-assets`
- **AND** it does not use a different hardcoded owner or repo

#### Scenario: HTTPS origin selects the API repo

- **WHEN** `assets-path` `origin` is `https://github.com/alice/overlay-assets`
- **THEN** Releases API paths use `alice/overlay-assets`

#### Scenario: Non-github origin hard-fails assets publish

- **WHEN** `update` will publish assets and `origin` is not a `github.com` owner/repo URL
- **THEN** the program logs an error and does not create a GitHub release
