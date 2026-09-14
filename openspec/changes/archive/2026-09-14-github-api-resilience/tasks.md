## 1. GitHub REST errors, fallback, and latch

- [x] 1.1 Add a structured `api.github.com` error (status, URL, JSON message, remaining, reset) plus a pure formatter and rate-limit/401 classifier; verify unit tests for 403 rate-limit, secondary-limit message, 401, non-rate-limit 403, and non-JSON body
- [x] 1.2 Thread that error through GitHub REST GET (keep headers; do not log secrets) and verify existing GitHub fake-HTTP tests still pass with richer `Left` text
- [x] 1.3 Stop GitMv `/releases/latest` → `/tags` fallback on HTTP 403/429; keep 404/empty fallback; verify a fake latest-403 never GETs `/tags` and a latest-404 still does
- [x] 1.4 Add a run-scoped `api.github.com` latch (new requests stop after the first rate-limit class or 401; in-flight may finish; `raw.githubusercontent.com` does not trip it) and verify concurrent fake-HTTP tests that a second tags GET is not started after the first 403 remaining=0

## 2. Health preflight

- [x] 2.1 Add injectable Statuspage `summary.json` + `GET /rate_limit` health (API Requests always when live GitHub; Git Operations only when assets `git push`; fail remaining=0, `/rate_limit` 401, required component `partial_outage`/`major_outage`; warn degraded and Statuspage fetch failure; `/rate_limit` transport failure hard-fails; success silent) and verify fakes for each of those outcomes without live network
- [x] 2.2 Skip health when this run will not call `api.github.com` (valid check-cache hits, no `--refresh`, no assets GitHub) and verify a cache-hit path does not GET Statuspage or `/rate_limit`
- [x] 2.3 Confirm `gencache` / `list` / `eclean` / `github-token` do not call the health helper; verify by inspection plus a gencache unit path that has no health HTTP

## 3. Decrypt when live GitHub and command abort

- [x] 3.1 After opening the check cache, detect live `api.github.com` need; if an envelope wins and live GitHub is needed, decrypt once on a controlling TTY (pause/resume); no TTY hard-fails without unauth fallback; verify fake-prompt tests for live miss (prompts), full cache hit (no prompt), and no-TTY (exit 1)
- [x] 3.2 Wire `outdated` and `update` plan to use the resolved/decrypted token for fetch/list; log one unauthenticated 60/hour warning only when a live unauth `api.github.com` call will happen; verify warning present on live unauth and absent on cache-hit and when a token is set
- [x] 3.3 On GitHub health / rate-limit / 401 abort: `outdated` emits completed stdout lines then `logError` and exit 1; `update` spine-fails; verify an integration fake where two packages complete outdated lines and a third 403 remaining=0 yields those lines, one error, exit 1
- [x] 3.4 Run Git Operations Statuspage check only at assets `git push`; verify GitMv-only update does not fail a fake Git Operations `major_outage`

## 4. Docs and quality gate

- [x] 4.1 Update `README.md` per `project-docs`: authenticated live fetch, envelope prompt, unattended env token for `outdated`/`update`, unauth 60/hour warning, health gate, rate-limit/401 exit 1, `gencache` excluded
- [x] 4.2 Expand Unit/Integration coverage per `test-coverage` (formatter, classifier, no-fallback, latch, health fakes, decrypt sequencing, abort emission) without live GitHub, live Statuspage, or interactive TTY
- [x] 4.3 `openspec validate github-api-resilience --strict --type change` and `hk check`; fix format/lint/weeder (no new unused exports, no blanket weeder roots)
