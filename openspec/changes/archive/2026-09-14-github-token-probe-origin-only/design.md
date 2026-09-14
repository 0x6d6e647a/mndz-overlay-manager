## Context

See proposal.md for motivation. `probeFineGrainedPat` currently lists `GET /user/repos?affiliation=owner`, treats `permissions.push == false` as public-read, and empty-POSTs `/releases` on other names (HTTP 403 accept, HTTP 422 = extra Contents: write). Live GitHub returned HTTP 422 on a public extra (`0x6d6e647a/advent-of-code-2021`) for a PAT whose UI grant is Only-select + Contents: write on the assets origin only. Extra 422 is not token-scoped write.

Prefix gate, origin `GET /repos/{owner}/{repo}`, and origin empty `POST /releases` → 422 (403 = missing Contents: write) stay. Injectable `HttpLbs` remains the probe seam. Fake-HTTP tests only.

## Goals / Non-Goals

**Goals:**

- Accept a PAT when the operator owns other public repositories.
- Probe only the assets origin (GET 2xx, empty POST 422).
- Remove extra-repo listing and extra POST from the setter.
- Keep classic-prefix, origin GET 404, and origin POST 403 fakes.

**Non-Goals:**

- Enforcing Only-select vs All repositories.
- Distinguishing extra private listed repos.
- Changing wrap/encrypt, `--force`, or env token resolution.
- New GitHub endpoints or dependencies.
- A live spike that origin 422 on a public origin is token-scoped Contents: write.

## Decisions

**1. Drop extra-repo checks entirely**

`probeFineGrainedPat` SHALL GET the origin repo, then empty-POST origin `/releases`. Delete `listOwnedRepos`, `OwnedRepo`, `refuseExtraContentsWrite`, and extra POST. Do not call `GET /user/repos`.

- *Alternative — ignore public extras, fail on extra private names:* Rejected; more API surface for a gap we accepted (All repositories with no extra privates still looks like Only-select).
- *Alternative — treat extra POST 422 as accept:* Equivalent to dropping extras, but still does N POSTs and keeps a false “write probe.” Delete the path.

**2. Tests: extra names must not fail; trap unused extra endpoints**

Replace extra-write 422-fail / extra 403-success with:

- Origin GET 200 + origin POST 422 succeeds even when the fake would 500 (or 422) on `/user/repos` or extra `/releases`.
- Keep classic `ghp_`, origin GET 404, origin POST 403.

Do not require live GitHub.

**3. README: Only-select is guidance**

Keep Fine-grained, Only select repositories (assets origin), Contents: write. State that GitHub’s always-on public-repo read does not fail `github-token`, and that the setter does not extra-check other owned repos. Remove language that Contents: write on any other *listed* repository is refused by the probe.

## Risks / Trade-offs

- **[All repositories + Contents: write passes]** → Accepted; README remains the Only-select contract.
- **[Origin empty POST 422 on a public origin may not prove token Contents: write]** → Same convention as today; 403 still means missing write when GitHub returns it; no live spike in this change.
- **[weeder after deleting extra-repo helpers]** → Remove dead code; do not add unused exports or blanket weeder roots.

## Migration Plan

No config or envelope migration. Operators who failed the extra-repo 422 re-run `github-token --force` with the same PAT. Rollback restores extra POST 422 refusal (correctly scoped PATs fail again if the operator owns other public repos).

## Open Questions

None that change specs or the task breakdown.
