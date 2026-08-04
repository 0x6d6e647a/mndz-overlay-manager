## Why

Multi-package `update` can fail mid-materialize with `no space left on device` under a small tmpfs `/tmp` (and similarly fill the manager distfiles cache) because concurrent full-path work opens large temp trees with no free-space check. Operators get late, opaque errors instead of an early, actionable failure naming the filesystem, free space, need, and remedies (`TMPDIR`, free space, lower `--jobs`).

## What Changes

- Add a **disk-space feasibility gate** for `update` that estimates per-unit write needs on the effective **TMPDIR** and **manager DISTDIR**, then hard-fails the command before concurrent heavy writes when free space cannot support the plan under current `--jobs`.
- Estimate needs from **last published asset size** (overlay Manifest `DIST` size and GitHub release asset `size`) times **ecosystem expansion factors** (named Haskell constants), plus ecosystem floors when no baseline exists, plus a fixed **256 MiB** safety margin per filesystem check.
- Treat **reuse** downloads with near-exact size (GH `size` × small factor); include **GitMv / ebuild manifest** manager-DISTDIR fetches for missing distfiles.
- When TMPDIR and manager DISTDIR resolve to the **same device**, use one combined budget.
- **Re-stat free space** at full-path admit and optionally after clone remeasure as unit-level safety (still no wait/queue pool).
- When live **Portage DISTDIR** is a different path and looks tight, **warn only** (product hard gates stay on paths `update` writes).
- Document `TMPDIR`, the gate, and remediation in **README**.
- Parse GitHub release asset **`size`** for reuse and baselines.

## Non-goals

- Disk **reserve/wait/timeout** pooling and wait UX (see repo `resource-scheduling.md`; same generation as future CPU tokens).
- **Serial heavy** materialize as the primary model (operators may still lower `--jobs`).
- Perfect prediction of Go module download peaks; factors are honest reservations, not exact peaks.
- Operator TOML/CLI for factors, floors, or `--skip-disk-check`.
- Changing default OS `/tmp` size or cgroup isolation.
- Hard-fail solely because system Portage DISTDIR is full when the manager uses a private path.

## Capabilities

### New Capabilities

- `disk-space-preflight`: Free-space estimation, multi-filesystem feasibility gate math (max / concurrent sum under `--jobs`), safety margin, baselines (Manifest + GH size), and unit-level recheck behavior for `update` heavy writes.

### Modified Capabilities

- `update-command`: Run disk-space feasibility as part of update preflight/spine before concurrent package mutation; hard-fail exit `1` with actionable messages when the gate fails.
- `manager-distfiles`: Manager DISTDIR is a hard free-space surface for planned manifest fetches (missing distfiles); already-present files need no additional reservation.
- `project-docs`: README documents TMPDIR, multi-FS free-space checks, estimate basis, and remediation for ENOSPC-class failures.

## Impact

- **Code:** New estimate/gate helpers (pure math + injectable free-space); wire into `update` spine/preflight and full-path admit; Manifest DIST size parse; `ReleaseAsset` gains `size`; Materialize/reuse paths supply baselines; progress step optional.
- **CLI:** No new flags required; messages reference `TMPDIR`, free space, and `--jobs`.
- **Specs/docs:** New capability + deltas above; README operator notes.
- **Tests:** Injectable free-space and baselines; unit tests for gate math (max, concurrent sum, same-FS merge, margin); no multi-GiB tmpfs required in CI.
- **Deferred:** Disk/CPU resource pools remain future work (`resource-scheduling.md`).
