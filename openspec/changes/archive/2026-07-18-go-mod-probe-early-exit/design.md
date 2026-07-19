## Context

Go tree-lane planning (`planGoPackageWithProgress`) today:

1. Discover Gentoo `dev-lang/go` ceilings (process-cached).
2. List all comparable GitHub tags, sort newest-first by PV.
3. Probe `go.mod` for **every** version via `mapConcurrently` under the work budget.
4. Select each lane target with `maxVersionUnder` (maximum package PV whose `go_req ≤` ceiling).

Step (3) dominates wall time and progress UI noise on packages with long tag histories. Lane selection only needs enough newest-first evidence to fill every ceilinged lane: the first parseable hit with `go_req ≤` ceiling is already the max for that ceiling when versions are ordered newest-first. No monotonicity assumption on `go_req` is required.

Version listing already returns PV-descending order (`listGitHubVersionsWith`). Ordering alone does not help without early exit.

## Goals / Non-Goals

**Goals:**

- Stop probing once every lane that has a ceiling has a selected package PV.
- Walk versions newest-first (existing list order).
- Keep identical lane targets vs full probe + `maxVersionUnder` for the same ceilings and go.mod contents.
- Coarsen progress: ceilings + list + one “probing go.mod” step for the whole walk.
- Stay under the existing process work budget for each probe.

**Non-Goals:**

- Changing GitHub tag pagination (no reverse pages, no partial list, no releases-only listing).
- Seeding probes from local overlay ebuild PVs.
- Batch/window concurrent probe walks for early exit.
- Changing ceiling discovery, KEYWORDS assembly, exact-set prune, or content-fix logic beyond continued go.mod cache hits for planned PVs.
- Changing go.mod URL/cache mechanics except how many keys planning requests.

## Decisions

### 1. Sequential newest-first walk with early exit

**Choice:** Replace “probe all, then select” with a single sequential loop over the already-sorted version list. After each successful parse of `go_req`, assign that PV to every still-unfilled lane where `go_req ≤` that lane’s ceiling. Stop when no ceilinged lanes remain unfilled, or the list ends.

**Why not keep full concurrent probe?** Concurrent full-set probe cannot early-exit without speculative over-fetch; sequential tip-first matches the frequent-run case (1–2 probes) and is simpler.

**Why not batch windows?** Frequent runs make N≈1–2; batch coordination adds complexity without meaningful wall-clock gain. Revisit only if large catch-up windows become common.

**Why not seed local PVs first?** Correctness does not require it; tip-first already prefers the upgrade window. Seeding can add probes when the tip already fills every lane. Deferred as a micro-opt.

### 2. Selection logic in-loop vs post-pass

**Choice:** Fill lane targets during the walk (first hit wins per lane under newest-first). Equivalent to collecting a prefix of `VersionCandidate`s and calling existing `selectAllLaneTargets` / `maxVersionUnder` on that prefix **if and only if** the prefix is a newest-first contiguous prefix that either exhausts the list or ends when all lanes are filled—and unprobed older versions cannot improve a max under a ceiling once a hit exists. That is true by definition of max under ordered scan.

Implementation may either:

- Maintain per-lane “best so far” while scanning, or
- Accumulate candidates until stop, then call `selectAllLaneTargets`.

Prefer reusing `selectAllLaneTargets` on the probed prefix if it keeps the code small and tests shared; either is fine if targets match.

### 3. Progress: three coarse steps

**Choice:** Package planning steps are:

1. Discovering go ceilings  
2. Listing versions  
3. Probing go.mod (entire early-exit walk)

Remove “step total = 2 + n versions” and per-probe `ppOnProbeDone` ticks as separate progress units. Optionally keep an internal callback for tests, but the production multi-progress row treats probing as one step: set total to 3 after ceilings start (or after list completes, still total 3), complete the third step when the probe walk finishes.

**Why not indeterminate probing?** Coarse determinate steps already match cli-activity multi-step rows; one probe step is enough when the walk is short.

### 4. Work budget and concurrency requirement

**Choice:** Each go.mod fetch still runs under `withWorkSlot`. Probes for a **single** package plan are sequential (one after another), so they do not compete with each other for overlapping in-flight slots on the same plan; they still serialize with other packages’ Go work via the shared budget.

The previous “many tags in flight for one plan” behavior is dropped for this path. Cross-package concurrency is unchanged.

### 5. Listing stays full-fetch

**Choice:** Continue `fetchAllTagNames` + PV sort. GitHub `/tags` is not PV-ordered and has no useful reverse-by-version pagination; partial pages are unsafe for max-under-ceiling when plain lanes need older PVs.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Bug in early-exit assigns non-max PV | Property/unit tests: early-exit targets equal full-probe targets on fixed fixture sets (including tip-too-new-for-plain and unparseable tags). |
| Worst case still probes all tags | Acceptable; no worse than today. Bootstrap / empty local / never-fits-ceiling still pays full cost. |
| Sequential walk slower than parallel full probe on huge catch-up | Acceptable for v1; frequent-run model dominates. |
| Progress regression if step total stays 2+n | Explicitly set total 3 and single probe step in `goPlanProgress`. |
| contentFix re-fetches go.mod | Planned PVs were probed during selection → cache hit; no change required. |

## Migration Plan

- Pure library/CLI behavior change; no config or overlay format migration.
- Ship behind normal quality gates (`hk check`); no feature flag required.
- Rollback: revert to probe-all if a selection mismatch is found.

## Open Questions

None remaining for v1; seed, batches, and pagination tricks are explicitly out of scope.
