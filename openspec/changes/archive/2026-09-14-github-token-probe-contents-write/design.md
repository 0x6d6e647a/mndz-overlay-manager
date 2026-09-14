## Context

See proposal.md for motivation. `Update.GitHubToken.probeFineGrainedPat` currently requires paginated `GET /user/repos?affiliation=owner` to return exactly `[assetsOrigin]`. GitHub documents that fine-grained PATs always include read-only access to all public repositories, so that list includes every public repo the operator owns. The prefix gate, `GET /repos/{owner}/{repo}`, and empty `POST /releases` → 422 (403 = missing Contents: write) stay.

`test/Test/Assets.hs` `testGitHubTokenProbe` pins the singleton-name check. Injectable `HttpLbs` remains the probe seam.

## Goals / Non-Goals

**Goals:**

- Accept a PAT whose only Contents: write grant is the assets origin when `/user/repos` also lists public-read owned repos.
- Still refuse Contents: write on any listed extra repository.
- Keep fail-closed prefix / GET-origin / empty POST 422 vs 403.
- Fake-HTTP tests only; no live GitHub in the coverage gate.

**Non-Goals:**

- Distinguishing Metadata-only extra *selected* public repos from always-on public read.
- Changing wrap/encrypt, `--force`, or env token resolution.
- New GitHub endpoints or dependencies.

## Decisions

**1. Extra-repo rule is Contents: write, not name equality**

Parse each `/user/repos` item as `full_name` plus optional `permissions.push`. Treat `permissions.push == false` as public-read (ignore). The assets origin still needs empty `POST /releases` HTTP 422.

- *Alternative — keep exact name singleton:* Rejected; that is the operator-facing bug.
- *Alternative — drop extra-repo check:* Rejected; “All repositories” + Contents: write would pass GET + origin POST 422.

**2. Confirm extra write with empty POST only when push is not clearly false**

For a listed extra repo:

- `permissions.push == false` → no further request.
- `permissions.push == true` or `permissions` / `push` omitted → empty `POST /repos/{extra}/releases` with `{}`. HTTP 403 means listed-but-not-writable (accept). HTTP 422 means Contents: write on an extra repo (hard-fail). Any other status or network error is fail-closed.

This covers token-scoped `permissions` (typical GitHub App model used by fine-grained PATs: extras are `push: false`, no extra POSTs) and user-scoped `permissions` (every owned repo might show `push: true`; extra POST 403 still accepts). Same 422/403 convention as the origin write probe; empty body creates no release.

- *Alternative — fail immediately on extra `push: true`:* Rejected; if GitHub reports owner-level push on public extras, the setter would still block the documented PAT form.
- *Alternative — always POST every extra name:* Works but does N extra POSTs even when `push: false` is present. Keep POST as confirmation, not the first filter.

**3. Tests encode both listing shapes**

Keep classic-prefix, origin GET 404, and origin POST 403. Replace “any extra name fails” with:

- Extra `push: false` + origin POST 422 → success.
- Extra `push: true` (or omitted permissions) + extra POST 422 → fail.
- Extra `push: true` (or omitted permissions) + extra POST 403 → success.

Do not require live GitHub.

**4. README states the GitHub public-read caveat**

Operator instructions stay: Fine-grained, Only select repositories (the assets origin), Contents: write. Add that GitHub always includes public-repo read-only and that `github-token` checks Contents: write on the origin, not an exclusive `/user/repos` name list.

## Risks / Trade-offs

- **[GitHub reports owner-level `push: true` on public extras]** → Extra empty POST 403 still accepts; tests cover that shape.
- **[Empty extra POST is not a documented dry-run]** → Same convention as the origin probe; 422 creates nothing; unexpected statuses fail closed.
- **[Metadata-only extra selected public repo looks like always-on public read]** → Accepted (proposal non-goal); Contents: write on extras is still refused.
- **[Many extra POSTs when `permissions` are omitted]** → Once per `github-token` run; pagination already exists.

## Migration Plan

No config or envelope migration. Operators who already failed the setter re-run `github-token --force` with the same PAT form. Rollback restores the name-singleton probe (correctly scoped PATs fail again if the operator owns other public repos).

## Open Questions

None that change specs or the task breakdown.
