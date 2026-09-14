## Context

See proposal.md for motivation. GitHub REST lives in `Update.GitHub` (`httpGetJson` keeps only `HTTP <code> from <url>`). `fetchGitHubWithHttpLbs` treats any latest-release `Left` as a tags fallback. `outdated` / `update` plan call `resolveGitHubToken`, which returns an env token or `Nothing` and never decrypts. Envelope decrypt is `usdUnlockConfigToken` on the update spine, only when assets GitHub is required. Check cache already skips live fetch on valid hits (`Update.CheckCache`). Concurrent checks use `mapConcurrentlyN`. `gencache` is local `egencache` + signed commit (no `api.github.com`).

## Goals / Non-Goals

**Goals:**

- One shared `api.github.com` error type, formatter, classifier, and run-scoped latch used by version fetch, tag list, `/rate_limit`, and other REST calls that already share `githubHeaders`.
- Decrypt-when-live-GitHub and health preflight sequenced after check-cache classification, before live REST.
- Injectable HTTP/health so the coverage gate never hits live GitHub or Statuspage.

**Non-Goals:**

- Cancelling in-flight `mapConcurrentlyN` workers.
- A remaining-count estimator or `retry-after` sleeper.
- Latching `raw.githubusercontent.com`.
- New CLI flags or config keys.

## Decisions

**1. Structured GitHub REST error, formatted at the log site**

Replace the `Left Text` status-only path for `api.github.com` with a small error value: HTTP status, URL, optional JSON `message`, optional remaining, optional reset (epoch). A pure formatter produces the operator log text. `logWarning` vs `logError` stays at the command boundary (per-package vs abort).

- *Alternative — keep `Left Text` and append body in `httpGetJson`:* Rejected; classification (rate-limit vs other 403 vs 401) would re-parse strings.
- *Alternative — print GitHub JSON on stdout:* Rejected; stdout is outdated lines only.

**2. Latch is a run-scoped flag on the GitHub REST helper**

Production GitHub REST (latest, tags pages, `/rate_limit`, assets REST that already uses the same headers) checks a shared “abort GitHub” flag before starting a new request. The first rate-limit-class 403/429 or 401 sets the flag. Classifier is pure: remaining `0`, or message indicating primary/secondary rate limit, or status 401. Other 403s do not set it. In-flight requests finish. `raw.githubusercontent.com` fetchers stay on their own path.

- *Alternative — stop the whole `mapConcurrentlyN` pool:* Rejected; extra cancel machinery for little quota saved.
- *Alternative — latch any 403:* Rejected; one private/missing repo would abort the overlay.

**3. GitMv fallback is status-aware**

`/releases/latest` → tags only when the error is not HTTP 403 or 429 (404 and parse/empty stay on the fallback). A rate-limit 403 on latest also sets the latch so tags is not started.

- *Alternative — disable tags fallback entirely:* Rejected; many repos have tags and no GitHub “latest” release.

**4. “Will this run call `api.github.com`?” is cache-then-policy**

After target resolution and opening the check cache:

- `--refresh` or a GitHub-source package without a valid latest/deps cache hit → live GitHub.
- `update` later: assets release lookup/create/upload/download or assets `git push` → live GitHub even if plan was cached.

Only then: env token or envelope decrypt (existing `decryptConfigEnvelope` + TTY prompt, pause/resume), then health, then package work. Full cache hit and no assets GitHub → no prompt, no health. Prompt at most once per process (existing decrypt cache).

- *Alternative — always decrypt on `outdated` if an envelope exists:* Rejected; wrap password on a 5-second cache hit.
- *Alternative — always health-check, including remaining=0, even on full cache hits:* Rejected; a cached `outdated` would die because the IP bucket is empty.

**5. Health is two injectable GETs, not a third-party monitor**

- `GET https://www.githubstatus.com/api/v2/summary.json` (no GitHub token). Inspect components named **API Requests** and, when this `update` will assets `git push`, **Git Operations**. Fail `partial_outage` / `major_outage`; warn `degraded_performance`; ignore other components. Statuspage transport failure → warn, continue.
- `GET https://api.github.com/rate_limit` with the resolved token (or unauthenticated). Does not consume quota. 401, `core.remaining == 0`, or transport failure → command fail. Remaining &gt; 0 never fails the preflight by itself.

Git Operations is **not** part of the `outdated` / early `update` plan preflight. Run it when classify/spine already knows an assets `git push` will happen (existing `goPush` site).

- *Alternative — `GET /zen` as health:* Rejected; it consumes quota and does not report incidents.
- *Alternative — page-level Statuspage `indicator`:* Rejected; Copilot/Actions incidents would fail overlay work.

**6. Command abort vs per-package reports**

`outdated` keeps deferred emission. On GitHub abort: clear the panel, emit completed stdout lines and ordinary soft warnings already collected, then `logError` and `exit 1`. Do not synthesize fetch-error warnings for packages that never started. `update` plan/mutate treats the same class as existing spine hard-fail (no further GitHub plan or apply).

## Risks / Trade-offs

- **[Unattended `outdated` with only an envelope hard-fails]** → Documented **BREAKING**; set `GITHUB_TOKEN` / `GH_TOKEN`. Same unattended rule as assets `update`.
- **[Statuspage lag vs real outage]** → `/rate_limit` still probes reachability and quota; Statuspage is incident signal only; Statuspage down is fail-open.
- **[In-flight jobs can still 403 after the latch]** → Accepted; avoids cancel/async complexity; no *new* requests start.
- **[Secondary rate limit has no remaining=0]** → Classifier also matches GitHub’s secondary-limit message; `/rate_limit` remaining may still be &gt; 0.
- **[False “live GitHub” if cache fingerprint misses]** → Existing check-cache miss already caused a live fetch; no new class of prompt.

## Migration Plan

Operators: no TOML schema change. Interactive `outdated` / `update` with `github-token` set will prompt when live GitHub is needed. Cron/CI must export `GITHUB_TOKEN` or `GH_TOKEN`. Rollback: revert the change; unauthenticated fetch and exit-0 403 warnings return.

## Open Questions

None that change specs, approach, or tasks.
