## Why

Unauthenticated `outdated` (and `update` plan) burns GitHub’s 60 request/hour IP quota, then logs a bare `HTTP 403 from <url>` per package and exits 0. The client already has the rate-limit body and headers, but drops them; GitMv then retries `/tags` after a 403 on `/releases/latest`. Operators with an encrypted `github-token` still go unauthenticated because `outdated` is specified not to decrypt.

## What Changes

- **BREAKING:** When this run will call `api.github.com` and the winning token is the config `mndz1.` envelope, `outdated` and `update` plan SHALL prompt for the wrap password (same TTY rules as assets decrypt). No controlling TTY SHALL hard-fail with exit `1`; the program SHALL NOT silently fall back to unauthenticated fetch. Unattended runs MUST set `GITHUB_TOKEN` or `GH_TOKEN`. A full check-cache hit with no live GitHub work SHALL NOT prompt.
- **BREAKING:** Primary/secondary rate-limit HTTP 403/429 and HTTP 401 from `api.github.com` SHALL be command-level hard failures (exit `1`), not per-package soft warnings that still exit 0. Ordinary per-package fetch errors (including non-rate-limit 403) stay warnings and do not change `outdated`’s exit 0.
- GitHub HTTP errors SHALL log status, GitHub JSON `message` when present, `x-ratelimit-remaining`, and `x-ratelimit-reset` via the logging system (`logWarning` for per-package, `logError` for command fail). Those details SHALL NOT be written to stdout.
- GitMv SHALL NOT fall back from `/releases/latest` to `/tags` when that first response is HTTP 403 or 429. 404 / empty latest still falls back.
- When this run will call `api.github.com`, after token resolve: `GET https://www.githubstatus.com/api/v2/summary.json` (API Requests; Git Operations only if this `update` will `git push` assets) and `GET /rate_limit` with the resolved token. Fail remaining=0, `/rate_limit` 401, or API Requests / Git Operations `partial_outage`/`major_outage`. Warn on `degraded_performance` and on Statuspage unreachable. `/rate_limit` unreachable is a hard-fail. Success is silent. No remaining floor other than 0.
- One `logWarning` when a live unauthenticated GitHub call will happen (60/hour). Skip that warning on a full cache hit.
- Shared latch: first rate-limit 403/429 or 401 on `api.github.com` stops new GitHub work; in-flight jobs finish; `outdated` emits completed stdout lines then the error. Latch does not apply to `raw.githubusercontent.com`.
- `gencache`, `list`, `eclean`, and `github-token` SHALL NOT run this health gate.

### Non-goals

- Requiring a GitHub token when none is configured (unauthenticated fetch remains allowed, with warning + fast-fail)
- Changing check-cache TTL, jobs, or pagination size
- Cancelling in-flight package jobs
- Health gating `gencache` / `list` / `eclean` / `github-token`
- Latching `raw.githubusercontent.com` 403s
- Waiting on `retry-after` / sleeping until reset
- GitHub Enterprise / non-`github.com` Statuspage
- New CLI flags

## Capabilities

### New Capabilities

- `github-api-resilience`: GitHub HTTP error diagnostics, rate-limit/401 classification and command latch, GitMv 403/429 no-fallback, Statuspage + `/rate_limit` health preflight (when this run will call `api.github.com`), unauthenticated live-fetch warning

### Modified Capabilities

- `github-auth`: Decrypt the config envelope when this run will call `api.github.com` (not only assets write); no silent unauth fallback when an envelope exists but decrypt cannot run
- `outdated-command`: Health/decrypt sequencing vs check cache; command hard-fail on GitHub health/rate-limit/401; emit completed outdated lines then error
- `update-command`: Decrypt before live GitHub plan/fetch, not only assets publish; Git Operations health only when this run will assets `git push`; abort plan/mutate on the same hard-fail class
- `project-docs`: README documents authenticated fetch for `outdated`/`update`, unattended env token, health gate, and rate-limit hard-fail
- `test-coverage`: Fake HTTP coverage for diagnostics, latch, no-fallback, Statuspage, `/rate_limit`, decrypt-when-live-GitHub (no live GitHub in the gate)

## Impact

- **Code:** `Update.GitHub` (headers, status/body/reset formatting, GitMv fallback, shared latch); new health helper (Statuspage + `/rate_limit`); `Update.Auth` / `app/Main` decrypt sequencing; `Update.Check` / spine plan abort; assets push path for Git Operations
- **Tests:** Injectable HTTP fakes only; no live `api.github.com` or Statuspage in the coverage gate
- **Docs:** `README.md` per `project-docs`
- **Operator:** Envelope + live GitHub now prompts; unattended needs env token; exhausted quota / bad token exits `1`
