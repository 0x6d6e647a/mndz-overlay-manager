# Spec Delta

## MODIFIED Requirements

### Requirement: GitHub health preflight before live api.github.com work

When `outdated` or `update` will perform at least one live `api.github.com` call this run, after resolving the GitHub token the program SHALL:

1. GET `https://www.githubstatus.com/api/v2/summary.json` and inspect the **API Requests** component. For `update`, also inspect **Git Operations** when this run will `git push` to the assets GitHub repository. The program SHALL hard-fail with exit `1` if a required component status is `partial_outage` or `major_outage`. It SHALL log a warning and continue if a required component is `degraded_performance`. Other components (Actions, Copilot, Pages, and similar) SHALL NOT fail the command. If Statuspage cannot be fetched, the program SHALL log a warning and continue.
2. GET `https://api.github.com/rate_limit` using the same Authorization rules as other GitHub REST calls for this run. If that response is HTTP 401, the command SHALL hard-fail. If `core.remaining` is `0`, the command SHALL hard-fail and the error SHALL include the reset time. If `/rate_limit` cannot be fetched, the command SHALL hard-fail. The program SHALL NOT fail the preflight solely because remaining is low but greater than zero. A successful health preflight SHALL NOT log an informational success line.

The program SHALL NOT run this preflight when this run will not call `api.github.com`. A valid check-cache hit for a stored latest or deps plan SHALL NOT by itself require this preflight, including when the plan still needs work. An uncached provider latest read, an uncached hypothetical consumer plan, `--refresh` when any selected package uses a GitHub update source, and assets GitHub lookup, publish, or push SHALL. `gencache`, `list`, `eclean`, and `github-token` SHALL NOT run this preflight.

#### Scenario: Remaining zero fails before tags

- **WHEN** `outdated` will live-fetch GitHub tags and `/rate_limit` reports `core.remaining` `0`
- **THEN** the program logs an error including the reset time
- **AND** it does not GET `/repos/.../tags` or `/releases/latest`
- **AND** it exits with status `1`

#### Scenario: API Requests major outage fails

- **WHEN** Statuspage reports component API Requests as `major_outage` and this run will call `api.github.com`
- **THEN** the command logs an error and exits with status `1` without package GitHub fetches

#### Scenario: Copilot down does not fail

- **WHEN** Statuspage reports Copilot as `major_outage` and API Requests as `operational`
- **THEN** the health preflight does not fail the command solely because Copilot is down

#### Scenario: Statuspage unreachable warns

- **WHEN** `https://www.githubstatus.com/api/v2/summary.json` cannot be fetched
- **THEN** the program logs a warning
- **AND** it continues to `/rate_limit` and package work unless that later step fails

#### Scenario: Full cache hit skips health

- **WHEN** `outdated` is run without `--refresh` and every `api.github.com` read for that run is a valid check-cache hit, including a deps plan that still needs work
- **THEN** the program does not GET Statuspage or `/rate_limit` solely for this health preflight

#### Scenario: Uncached hypothetical plan runs health

- **WHEN** `outdated` will run an uncached hypothetical consumer plan or an uncached overlay-provider latest read
- **THEN** the program runs this health preflight before that read

#### Scenario: Git Operations checked only before assets push

- **WHEN** `update` will `git push` assets to GitHub
- **THEN** the program applies the Git Operations component rule before that push
- **WHEN** `update` will not `git push` assets (GitMv-only, or no assets publish)
- **THEN** Git Operations outage SHALL NOT fail the command solely via this preflight

#### Scenario: gencache skips GitHub health

- **WHEN** the operator runs `gencache`
- **THEN** the program does not GET Statuspage or `/rate_limit` as a GitHub health preflight

### Requirement: Unauthenticated live GitHub fetch warns once

When `outdated` or `update` will perform a live `api.github.com` call and no GitHub token was resolved (no environment token and no decrypted config envelope), the program SHALL log exactly one warning that unauthenticated GitHub requests are limited (60 per hour) and that the operator may set `GITHUB_TOKEN`, `GH_TOKEN`, or `github-token`. The program SHALL NOT emit that warning when this run will not call `api.github.com`, or when a token was resolved.

#### Scenario: Live unauth outdated warns

- **WHEN** `outdated` will live-fetch GitHub tags and neither env nor config token is available
- **THEN** the program logs one warning about the unauthenticated 60-per-hour limit

#### Scenario: Cache-hit unauth does not warn

- **WHEN** `outdated` completes from valid check-cache hits with no live `api.github.com` call, including when a cached plan still needs work
- **THEN** the program does not log the unauthenticated-quota warning solely for that run
