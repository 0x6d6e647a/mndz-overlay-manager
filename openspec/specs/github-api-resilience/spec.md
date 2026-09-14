# github-api-resilience Specification

## Purpose

Make GitHub REST fetch for overlay version checks and updates fail closed on rate-limit and auth rejection, surface GitHub’s own error and quota fields in logs, and skip doomed live API work via a Statuspage plus `/rate_limit` preflight.

## Requirements

### Requirement: GitHub API error logs include status, message, and rate-limit fields

When the program reports an HTTP error from `api.github.com`, the log line SHALL include the HTTP status, the request URL, the GitHub JSON `message` field when the body is JSON and that field is present, and the `x-ratelimit-remaining` and `x-ratelimit-reset` values when those response headers are present. Per-package fetch failures SHALL use warning-level logs. Command-level GitHub hard failures SHALL use error-level logs. Those details SHALL NOT be written to standard output. The program SHALL NOT log the raw token, wrap password, or ciphertext.

#### Scenario: Rate-limit 403 warning includes GitHub message and reset

- **WHEN** a per-package `api.github.com` response is HTTP 403 with JSON message `API rate limit exceeded` and `x-ratelimit-remaining` is `0`
- **THEN** the warning log includes `403`, the URL, that message, remaining `0`, and the reset time
- **AND** standard output does not contain that GitHub message

#### Scenario: Non-JSON body still reports status and URL

- **WHEN** an `api.github.com` error body is not JSON
- **THEN** the log still includes the HTTP status and URL
- **AND** the program does not dump a raw HTML body

### Requirement: Rate-limit and 401 on api.github.com are command hard-fails

HTTP 403 or 429 from `api.github.com` SHALL be treated as a **rate-limit class** failure when `x-ratelimit-remaining` is `0` or the JSON `message` indicates a primary or secondary rate limit. HTTP 401 from `api.github.com` SHALL be treated as a **token-rejected** failure. Other HTTP 403 responses (for example a missing repository) SHALL remain per-package fetch errors as specified by `outdated-command` and `update-command`.

A rate-limit class or token-rejected failure SHALL hard-fail the command with exit status `1`. After the first such failure, the program SHALL NOT start new `api.github.com` work for that run. Requests already in flight MAY finish. HTTP errors from `raw.githubusercontent.com` SHALL NOT by themselves trip this latch. The program SHALL NOT wait for `x-ratelimit-reset` or `retry-after` before exiting.

#### Scenario: Rate-limit 403 aborts remaining GitHub work

- **WHEN** `outdated` or `update` receives an `api.github.com` HTTP 403 whose remaining header is `0` while other packages still need GitHub fetches
- **THEN** the command logs an error that includes the GitHub message and reset
- **AND** it does not start further `api.github.com` requests
- **AND** it exits with status `1`

#### Scenario: 401 aborts the command

- **WHEN** `api.github.com` returns HTTP 401 for a version or rate-limit request in this run
- **THEN** the command logs an error that the GitHub token was rejected
- **AND** it exits with status `1`
- **AND** it does not continue checking remaining GitHub packages as soft fetch failures

#### Scenario: Non-rate-limit 403 stays per-package

- **WHEN** `api.github.com` returns HTTP 403 for one repository and the remaining header is not `0` and the message is not a rate-limit message
- **THEN** that package is a fetch-error warning
- **AND** other packages continue
- **AND** `outdated` still exits `0` if the spine otherwise succeeds

#### Scenario: raw.githubusercontent.com 403 does not latch

- **WHEN** a go.mod or similar fetch from `raw.githubusercontent.com` returns HTTP 403
- **THEN** that failure is reported for that package or plan
- **AND** the program does not treat it as the `api.github.com` rate-limit latch

### Requirement: GitMv does not fall back to tags after 403 or 429

When GitMv latest-release fetch uses `GET /repos/{owner}/{repo}/releases/latest` and that response is HTTP 403 or 429, the program SHALL NOT request `/repos/{owner}/{repo}/tags` as a fallback for that package. HTTP 404 or an empty/missing latest release SHALL still fall back to tags as before.

#### Scenario: Latest 403 skips tags

- **WHEN** `/releases/latest` returns HTTP 403
- **THEN** the program does not GET `/tags` for that owner/repo as a fallback

#### Scenario: Latest 404 still lists tags

- **WHEN** `/releases/latest` returns HTTP 404
- **THEN** the program MAY GET `/tags` to obtain a comparable version

### Requirement: GitHub health preflight before live api.github.com work

When `outdated` or `update` will perform at least one live `api.github.com` call this run, after resolving the GitHub token the program SHALL:

1. GET `https://www.githubstatus.com/api/v2/summary.json` and inspect the **API Requests** component. For `update`, also inspect **Git Operations** when this run will `git push` to the assets GitHub repository. The program SHALL hard-fail with exit `1` if a required component status is `partial_outage` or `major_outage`. It SHALL log a warning and continue if a required component is `degraded_performance`. Other components (Actions, Copilot, Pages, and similar) SHALL NOT fail the command. If Statuspage cannot be fetched, the program SHALL log a warning and continue.
2. GET `https://api.github.com/rate_limit` using the same Authorization rules as other GitHub REST calls for this run. If that response is HTTP 401, the command SHALL hard-fail. If `core.remaining` is `0`, the command SHALL hard-fail and the error SHALL include the reset time. If `/rate_limit` cannot be fetched, the command SHALL hard-fail. The program SHALL NOT fail the preflight solely because remaining is low but greater than zero. A successful health preflight SHALL NOT log an informational success line.

The program SHALL NOT run this preflight when this run will not call `api.github.com` (valid check-cache hits for every selected GitHub source, and no assets GitHub lookup/publish/push). `--refresh` counts as live GitHub when any selected package uses a GitHub update source. `gencache`, `list`, `eclean`, and `github-token` SHALL NOT run this preflight.

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

- **WHEN** `outdated` is run without `--refresh` and every selected GitHub-source package has a valid check-cache hit
- **THEN** the program does not GET Statuspage or `/rate_limit` solely for this health preflight

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

- **WHEN** `outdated` completes from valid check-cache hits with no live `api.github.com` call
- **THEN** the program does not log the unauthenticated-quota warning solely for that run
