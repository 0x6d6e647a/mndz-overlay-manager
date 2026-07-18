## Context

`update` apply currently runs concurrent per-package phase 1 work, then a **barrier** phase 2 that signs overlay commits for every `ApplySuccess` whose paths are still uncommitted. That model fits single-mutation `GitMvAndManifest`. For `GoVendorAndAssets`, tree-lane planning can require **multiple planned PVs** in one package storm. Each PV writes an ebuild and regenerates the shared package `Manifest` via `ebuild … manifest`. The next PV’s dirty check then sees uncommitted `Manifest` dirt and hard-fails—even when the operator started clean. Observed with multi-lane packages such as `dev-util/crush` (e.g. stable-lane older PV plus tip content-fix).

Separately, Go BDEPEND content-fix uses **presence** of `dev-lang/go` (`ebuildHasDevLangGoBdepend`) rather than **match** against that PV’s `go.mod` `go` directive (`goBdependMatches`). Soft-skip “already matches plan” can therefore leave wrong or missing atoms. Planning already probes `go.mod` per candidate tag into a cache; that data is not fully used for content-fix.

GPG readiness already runs before every signed commit (overlay and assets). Assets publish already commits mid–phase 1 under `aeAssetsLock`.

## Goals / Non-Goals

**Goals:**

- Commit each successful **apply unit** immediately so the overlay worktree is clean relative to HEAD for the next unit (C-everywhere).
- Keep concurrent package apply; serialize only overlay (and existing assets) git mutations.
- Preserve partial multi-PV success and prune-only-on-full-package-success.
- Treat Go BDEPEND as needs-work when missing **or** not equal to the PV’s probed/cloned `go.mod` requirement; soft-skip only when BDEPEND matches.
- Keep dirty-before-mutate for **foreign** uncommitted dirt.

**Non-Goals:**

- F3 `--force` / operator dirty override.
- Self-dirt allowlists (strategy B) or dirty-once-only without commits (strategy A).
- Changing assets publish/reuse protocol beyond “overlay commit moves earlier.”
- `GOTOOLCHAIN=auto` or downloading toolchains.
- Guaranteeing global overlay commit order by `category/package` under concurrency.

## Decisions

### D1 — Commit-on-unit-success (C-everywhere)

**Choice:** After a unit successfully mutates the overlay and passes integrity checks, take the overlay git lock, `git add` unit paths, `git commit -S` with the existing message shape (`category/package: version`), and only then record `ApplySuccess`.

**Units:**

| Unit | When | Commit message |
|------|------|----------------|
| GitMv package | After rename + successful `ebuild manifest` | `category/package: <remote PV>` |
| Go planned PV | After overlay write + manifest + SHA512 verify (full or reuse) | `category/package: <PV or -rN as written>` |
| Go prune | After all planned PVs for the package succeeded and extras were deleted + Manifest refreshed | Prefer attaching prune pathspecs to a **final dedicated commit** with message `category/package: prune obsolete ebuilds` (or fold into the last PV commit only if prune runs before that commit—prefer dedicated commit for clarity) |

**Rationale:** Pure git transactions; no self-dirt bookkeeping; crash after PV₁ leaves PV₁ committed so retries plan remaining work. Matches “C is most correct.”

**Alternatives rejected:**

- **A (dirty-once):** Simple but blind to mid-storm foreign dirt and still leaves uncommitted multi-PV state until barrier.
- **B (allowlist self-dirt):** Fixes the Manifest false positive without moving commits; requires path-set plumbing and still leaves crash-between-PVs dirty.
- **C-Go-only:** Two commit lifetimes; more confusion for little gain.

### D2 — Retire deferred overlay commit barrier

**Choice:** Remove phase-2 `commitSuccesses` over pending paths as the success path. `applyOverlay` collects already-committed outcomes (and hard-fails/soft-skips). Optionally keep a no-op or assert that no `ApplySuccess` still has uncommitted paths in tests.

**ApplySuccess meaning:** Success lines for stdout + “this unit is in HEAD.” Path list may remain for logging/tests but MUST NOT imply a later commit.

**Signing failure:** If mutate succeeded and commit/sign fails → hard-fail that unit with half-applied warning (tree may be dirty); same as today’s commit-phase hard-fail, just earlier.

### D3 — Overlay git lock

**Choice:** Add `aeOverlayLock :: MVar ()` (or equivalent) on `ApplyEnv`, held around every overlay `git add` + `git commit -S`. Assets path keeps `aeAssetsLock`. Order for full Go path remains: assets critical section (if any) → overlay mutate → overlay lock commit (do not hold assets lock across overlay mutate/commit).

**Rationale:** Spec already required mutual exclusion for overlay index ops; barrier made it accidental. Concurrent jobs make the lock mandatory under C.

### D4 — Dirty checks stay per unit (no allowlist)

**Choice:** Before mutating a unit, check involved paths (template/newest ebuild + `Manifest` for that unit) dirty vs HEAD. After prior unit commit, those paths are clean unless foreign dirt remains.

**Multi-PV scenario:** PV₁ commit includes ebuild + Manifest; PV₂ dirty check passes.

### D5 — Partial success and prune

**Choice:** Keep current product rule: earlier PV units may succeed (and commit) while a later unit hard-fails; package storm continues for remaining planned PVs only if desired—**default: continue sequential PVs after a hard-fail** only when safe; simpler and aligned with today: **stop further materializations for that package after first hard-fail**, still return prior successes + the failure (today returns all results from `mapM` even after failures—prefer **stop on first hard-fail within a package** to avoid compounding dirt after half-apply). Document: sequential `materializeOne`; on hard-fail, do not start later PVs; do not prune; return successes so far + failure.

**Prune:** Only if every planned need-PV materialization succeeded (no hard-fail in the package storm). Prune is its own commit unit under overlay lock.

### D6 — Full BDEPEND vs go.mod + probe cache

**Choice:**

- Content-fix needs go version for each planned PV that already has a local ebuild: obtain from go.mod probe cache (planner / `PlanOps` / `fetchGoModVersion` key by owner/repo/tag/subdir).
- `ebuildNeedsContentFix` (or successor) takes optional required go version: needs fix if SRC_URI/KEYWORDS bad, Manifest missing vendor DIST, **or** required go is `Just ver` and not `goBdependMatches ver content`, **or** required go is known and atom absent.
- Soft-skip “already matches plan” uses the same rule.
- On apply rewrite: always `ensureGoBdepend` when `mGoVer` is known; if content-fix was solely for BDEPEND and go.mod cannot be obtained → hard-fail that PV (do not soft-skip or silent no-op).
- Presence-only `ebuildHasDevLangGoBdepend` alone is insufficient for needs-work.

### D7 — Commit ordering under concurrency

**Choice:** Relax global sort-by-`category/package` for overlay commits. Order is completion order under the overlay lock. Each commit remains path-isolated to its unit.

### D8 — Progress / GPG UX

**Choice:** Accept interleaved overlay pinentry with apply work (same class of UX as assets commits). Reuse existing `ensureGpgReady` before each overlay commit. No new “warm all commits at end” phase.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| More pinentry prompts if agent cache expires between long PV units | Existing readiness + agent cache; assets already mid-run; document operator expectation |
| Concurrent packages interleave commits (non-sorted history) | Path isolation; relax sort requirement in spec |
| Half-apply after write, before commit still dirty | Existing half-applied warning; F3 out of scope |
| Prune commit message / empty prune | Skip commit if no extra paths; dedicated message when paths non-empty |
| BDEPEND content-fix needs network/probe for every present PV | Reuse go.mod cache from planning; probes already run for candidates under ceiling |
| Stopping later PVs after first hard-fail changes today’s `mapM` continue-all | Safer; document in tasks/tests; partial success still commits earlier PVs |
| Tests assume barrier `commitSuccesses` | Update tests to expect commit inside unit apply |

## Migration Plan

1. Implement overlay lock + commit-inside-unit for GitMv and Go; remove barrier commit loop.
2. Wire BDEPEND match into content-fix / outdated / soft-skip.
3. `hk check` / unit tests green.
4. Operator smoke: multi-PV Go package (e.g. crush) with two need-PVs completes two overlay commits without dirty self-fail; package with wrong BDEPEND shows outdated and gets fixed on update.

Rollback: revert change; no on-disk schema migration.

## Open Questions

None blocking. Resolved in explore:

- C-everywhere (not C-Go-only).
- Full BDEPEND (missing + mismatch).
- Probe-backed content-fix.
- Partial success retained; prune only on full package success.
- F3 out of scope.

Implementation detail (non-blocking): exact prune commit message string—default `category/package: prune obsolete ebuilds` unless a stronger convention appears in review.
