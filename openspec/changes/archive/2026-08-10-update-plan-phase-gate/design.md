## Context

See `proposal.md` — Why. Today `runUpdate` (`app/Main.hs`) computes `selected` from inventory or CLI filter, sets `AssetsPreflight` from technique on that set, runs tools/assets/token preflight, then `buildUnitPlansForPackages selected` (every `DepsAndAssets` → full-path estimate) and `runDiskSpaceGate` **before** opening the check cache and before apply discovers soft-skips. Apply already plans per package (`checkPackage` / runtime-lane plan + `planNeedsWork`) and soft-skips; reuse vs full is decided later inside materialize via `ReleaseOps`. Living `update-command` already says the disk gate is for packages that need work; archive design D2 for `update-disk-space-preflight` intended needs-work first but implementation overestimated.

Constraints: keep injectables (`DiskSpaceProbe`, `DepsPlanOps`, `ReleaseOps`, `Fetcher`); project-local quality tools; do not weaken weeder/stan casually; prefer `other-modules` for new internals.

## Goals / Non-Goals

**Goals:**

- Spine: spine tools → plan → conditional preflight (A2) → classify → disk gate → mutate.
- Disk units only from needs-work heavy work, with reuse vs full estimates.
- Maximal plan/mutate split with outcomes carried from plan hard-fails (mutate skips those keys).
- Testable pure unit builders, fake-ops integration, and extracted spine used by Main.

**Non-Goals:**

- Soft-skip message removal or empty-run early exit.
- Resource pools / factor recalibration.
- Live GitHub CI E2E.

## Decisions

### D1: Spine order

**Choice:**

```text
resolve selected
open check cache (--refresh honored)
spine tools: git, ebuild, egencache, gpg
layout + manager distfiles probe (existing)
PLAN PHASE (multi-progress, --jobs)
  needs-work vs soft-skip vs plan hard-fail
if needs-work ∩ DepsAndAssets:
  hard-require token, assets-path, xz; prepare SSH
  language tools: go/npm/bun only if any planned unit is full-path for that eco
  cargo tools if any cargo package needs work (P1 includes reuse-only cargo work)
CLASSIFY assets units (after token/assets require)
  → UnitDiskPlan list + package hard-fails
DISK GATE on heavy units only
MUTATE always (walk selection; skip plan hard-fail keys; soft-skip up-to-date)
one cache hit/fetch summary
```

**Why:** Matches operator truth for free space and tools; token available before reuse probe; avoids classifying without auth.

**Alternatives:** Classify during plan with optional token — rejected (wrong class / public-only). Conditional tools before plan — rejected (technique overcount).

### D2: Plan phase semantics

**Choice:** Reuse existing outdated/apply planning: GitMv latest compare; DepsAndAssets runtime-lane plan + local content/Manifest adequacy (`planNeedsWork`). Check cache lookup/store as today. Cache hit: no upstream plan network; still local adequacy. Concurrency: same `--jobs` as apply. Progress: multi-progress “Planning packages” (or equivalent); on hit, skip long network sub-step labels.

**Why:** Single definition of needs-work; cache makes bare `update` after `outdated` cheap.

**Alternatives:** Heuristic “Manifest only” needs-work — rejected (wrong for lane gaps).

### D3: Classify policy (reuse vs full vs fail)

| Probe result | Class | Package |
|--------------|-------|---------|
| Matching asset + usable size | Reuse (need from size × ~1.1 + margin) | Continue |
| Matching asset, size missing | Reuse (Manifest same-class DIST or reuse floor + margin) | Continue |
| No release / no matching asset | Full path (Manifest/full factor or floor + margin) | Continue |
| API/network/parse error | — | Hard-fail package; exclude from gate |
| Token unusable at hard-require | — | Spine fail before classify |

**Why:** Missing asset means full path (normal first publish), not failure. Probe errors are not safe to overestimate as full path under A2 (would demand language tools and inflate free space). Supersedes archive D2 “unknown → full-path overestimate” for **probe errors only**.

**Alternatives:** Overestimate full on any unknown — rejected. Hard-fail when size missing — rejected (C3a).

### D4: Disk unit set

**Choice:**

- Only packages that need work and will perform heavy temp and/or manager-distfiles writes.
- Multi-PV sequential work within one package: one concurrent contribution = **max** single-PV need (not sum).
- Prune-only or content-only with no materialize/fetch: **no** unit.
- GitMv outdated: existing dist-oriented estimate (temp 0).
- Plan fetch failures and classify hard-fails: **exclude** from units (package already failed).

**Why:** Concurrent sum under `--jobs` must match packages that can hold reservations.

### D5: Maximal plan/mutate split

**Choice:** Extract first-class plan phase API and mutate phase that consumes plan results (needs-work set, per-unit class, carried hard-fail outcomes). Main calls a testable spine orchestrator (e.g. `runUpdatePhases` or equivalent) rather than inlining all logic.

**Why:** User-selected maximal refactor; enables I1+I2 tests.

**Alternatives:** Thin filter in Main only — rejected (user chose maximal).

### D6: Mutate always; D1 carry-forward

**Choice:** After a successful disk gate (or empty units pass), always enter mutate/apply. No early exit when needs-work is empty. Mutate **skips** package keys already hard-failed in plan/classify and merges those outcomes into the final list for exit aggregation.

**Why:** Avoid special-case empty exit; preserve soft-skip presentation for up-to-date packages; avoid double-planning failed keys.

### D7: Conditional tools A2

**Choice:** Derive `AssetsPreflight` from plan + classify results, not `entryNeedsEco selected`. Cargo P1: any cargo package that **needs work** requires `pycargoebuild` + fetcher even if all its units are reuse. Bare `update` with only GitMv/binary needs-work and up-to-date deps packages must not require `go`/`npm`/`bun`/token/assets solely due to inventory technique.

**Why:** Spec “will attempt” / full-path language tools; closes cousin issue in the same structural change.

### D8: Testing strategy

**Choice:**

1. Pure: estimate math; plan results → `[UnitDiskPlan]` (max-PV, reuse/full/omit).
2. Fake `ReleaseOps` / `DepsPlanOps` / `Fetcher` / `DiskSpaceProbe`: classify table; needs-work filter; gate pass with free space for one package only when inventory has many heavy packages.
3. Extracted spine integration tests with temp overlay + injected ops.
4. No live GitHub required in CI.

### D9: Module layout

**Choice:** Prefer focused helpers under `Update.DiskSpace` / plan-aware builders (possibly `Update.Apply.Plan` or spine module) as `other-modules` unless tests need export. Keep production `getFreeBytes` / gate math; replace or demote `buildUnitPlansForPackages` full-inventory full-path path as product entry.

### D10: Progress vs sequential preflight

**Choice:** Plan uses multi-progress (like `outdated`). Conditional tools + disk gate remain sequential step bar (or disk as one step after plan). Mutate keeps existing multi-progress “Updating packages.”

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Double network if mutate re-plans | Mutate consumes plan results / cache; skip plan hard-fails |
| Classify after plan adds latency | Only for needs-work ∩ assets; cache does not store release size (accept); optional later cache |
| A2 requires classify before language tools | Order: conditional tools for assets/token first; language tools after classify (or require full-path tools only after class known — if tools step is one block, run classify then tools then gate) |
| Token hard-require after plan but before classify | Documented in D1; spine fail C5a |
| Maximal split churn / weeder | Entrypoint-oriented roots; no blanket root-modules |
| False hard-fail on flaky GH | Per-package fail; siblings continue; retry is operator re-run |

**Ordering note for A2 tools:** Strict reading is: classify before knowing full-path language tools. Implementation should: complete classify → set `AssetsPreflight` (assets + language) → run conditional tool checks → disk gate. Token must be available for classify: require token/assets path existence before classify without requiring `go` until class is known. Practical sub-order:

```text
if needs-work ∩ DepsAndAssets:
  require token + assets-path + xz (+ SSH prep)
CLASSIFY
set language/cargo flags from classes
check language/cargo tools on PATH
DISK GATE
```

## Migration Plan

- Purely behavioral on `update`; no config migration.
- Operators who relied on over-broad tool failure before any work see fewer false fails.
- Rollback: revert change; no on-disk format change beyond normal check-cache use.

## Open Questions

None blocking. Factor constants unchanged unless calibration is separate.
