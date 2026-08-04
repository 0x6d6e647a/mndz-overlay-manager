## Context

See `proposal.md` for motivation (ENOSPC under concurrent full-path materialize on small tmpfs). Today `update` preflight covers tools, assets path/token, and manager distfiles create-then-rename probe (`Update.Preflight`, `Update.Distfiles`, `app/Main.hs`). Heavy writers use `withSystemTempDirectory` under TMPDIR (`Go.Vendor`, `Cargo.Crates`, `Npm.Cache`, `Bun.Cache`, `Sbcl.Deps`, plus `mndz-deps-out-` / `mndz-reuse-asset-` in `Apply.Materialize`). Package concurrency is `mapConcurrentlyN` (`--jobs`); there is no disk or heavy lane. Exploration notes: `tmp-space-and-cpu-resource-scheduling.md`, deferred pool: `resource-scheduling.md`.

## Goals / Non-Goals

**Goals:**

- Command-level free-space feasibility before concurrent heavy writes, honest under `--jobs` (max + concurrent sum of up to N largest unit needs).
- Per-unit estimates from Manifest DIST size and GitHub asset `size` × ecosystem factors + **256 MiB** fixed margin.
- Hard surfaces: effective temp root + manager DISTDIR; same-device merge; present distfiles need 0 on DISTDIR.
- Warn-only for distinct live Portage DISTDIR when tight.
- Unit-level re-`statvfs` at full-path admit; post-clone remeasure when cheap.
- Injectable free-space for tests; README operator docs.

**Non-Goals:**

- Disk reserve/wait queue, timeout UX, CPU tokens (later; `resource-scheduling.md`).
- Serial heavy as primary design.
- Config/CLI for factors or skip flags.
- Perfect peak prediction.

## Decisions

### D1: Static concurrent sum gate (no pool)

**Choice:** Compute needs for planned units; hard-fail if `free < max(need)` or `free < sum(top N needs)` per FS/device. No wait.

**Why:** Matches locked product direction without implementing a disk pool. Conservative when `max ≤ free < sum` (refuses runs a future pool could serialize).

**Alternatives:** Serial heavy (K=1) — simpler free math, underuses machines; reserve-and-wait pool — deferred.

### D2: When to estimate

**Choice:** Hybrid command-scoped pass after packages needing work are known (and after reuse vs full is known where a release probe already runs or can be done cheaply for the gate), then existing apply; recheck free at full-path admit.

**Why:** Accurate concurrent sum needs full vs reuse classification and baselines. Admit recheck covers external space loss after the gate.

**Implementation sketch:**

1. Resolve selected packages that need work (existing target/plan paths as much as possible without full mutation).
2. For each heavy unit: classify reuse vs full when known; else assume full-path for that unit (safe overestimate).
3. Load baselines (Manifest, GH size); compute needs; merge devices; `statvfs`; gate.
4. Apply; on full-path entry re-`statvfs` for unit need.

If a precise reuse probe for every package before apply is too expensive, prefer overestimating as full-path for the command gate (false fail is recoverable; false pass is ENOSPC).

### D3: Estimate formula and constants

**Choice:** Named Haskell constants for:

| Symbol | Starting value (calibrate) |
|--------|----------------------------|
| Go full-path factor on compressed baseline | `5` |
| Cargo factor | `12` |
| npm/Bun factor | `4` |
| Sbcl factor | `10` |
| Reuse factor | `1.1` |
| DISTDIR fetch factor on missing file size | `1.1` |
| Safety margin | **256 MiB** fixed |
| Ecosystem floors (no baseline) | Go 3 GiB temp; Cargo 1.5 GiB; Bun/npm 1.5 GiB; Sbcl 2 GiB; reuse 512 MiB; small GitMv floor from typical bins or 512 MiB |

```text
required = floor_or (baseline * factor) + 256 MiB
```

**Why:** Constants avoid config surface; sizes stay data-driven from Manifest/GH.

**Alternatives:** Percent margin — rejected in favor of fixed 256 MiB; hardcoded per-PN GiB table — rejected (rots).

### D4: Baseline sources

**Choice:**

1. Parse Manifest `DIST <name> <size> …` for latest related asset of the right class under the package dir.
2. GitHub `ReleaseAsset` includes `size` (`parseReleaseAsset`); use for reuse and prior tags when useful.
3. Else ecosystem floor.

**Why:** Manifest is offline and already correct for overlay packages; GH size is in scope and exact for reuse.

### D5: Multi-FS and same device

**Choice:** Hard-check temp + manager DISTDIR. `statDevice` / equivalent to merge. Portage DISTDIR via existing `lookupPortageDistDir` / fallback — warn if free below a simple threshold (e.g. free &lt; 1 GiB or free &lt; 256 MiB + small floor), never sole hard-fail when path ≠ manager.

### D6: Free-space API

**Choice:** Thin injectable `getFreeBytes :: FilePath -> IO (Either Text Integer)` using POSIX `statvfs` (unix package already available via stack/platform; prefer existing deps). Production uses real `statvfs`; tests inject fake free maps.

### D7: Module layout

**Choice:** Prefer a focused module e.g. `Update.DiskSpace` (or `Update.Preflight.DiskSpace`) for:

- roots resolution
- estimate pure functions
- concurrent sum / max pure functions
- gate orchestration
- margin/factor constants

Wire from `app/Main.hs` update spine (preflight steps) and `Apply.Materialize` admit. Extend `ReleaseAsset` in `Update.Assets.Release`. Manifest size parse near `Update.EbuildEdit` or DiskSpace.

Keep pure math heavily unit-tested; avoid expanding `exposed-modules` without need (prefer `other-modules` unless tests/app require export).

### D8: Progress

**Choice:** Add one sequential preflight step (e.g. “disk space”) in existing `runPreflightSteps` / assets preflight progression so TTY users see the check.

### D9: Error copy (sketch)

```text
insufficient free space for update under --jobs N:
  temp root: /tmp (tmpfs)  free: 1.9G  need: 5.2G (concurrent sum)
  manager distfiles: ~/.cache/.../distfiles  free: 12G  need: 0.8G
  hint: free space, or TMPDIR=$HOME/local/tmp, or lower --jobs
```

### D10: Post-clone remeasure

**Choice:** After successful clone in builders (or a shared helper), `du`-equivalent (directory walk file sizes) when practical; if `measured + remainingEstimate > free`, unit hard-fail. Skip if measurement fails.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Factors underestimate real peak (Go zip+extract) | Conservative starting factors; 256 MiB margin; admit + post-clone recheck; tune constants after real runs |
| Factors overestimate → false fail | Operator lowers jobs / sets TMPDIR; floors only without baseline; document |
| Gate before full plan knows all units | Overestimate unknown as full-path; refine when plan already ran for DepsAndAssets |
| `statvfs` on non-Unix | Product is Linux Gentoo operator tool; acceptable |
| Same TOCTOU between gate and start without pool | Admit recheck; pool later for true concurrent packing |
| Double-count temp and DISTDIR lifetime | Prefer concurrent peak model per FS; document that full path peaks on temp first then DISTDIR fetch may follow after temp cleanup — if both held, same-device merge covers sum of simultaneous holds; if sequential within unit, use max of phases not sum within one unit where known |

## Migration Plan

- Purely additive behavior on `update`; no config migration.
- Operators who relied on starting work that would ENOSPC now see early fail — intended.
- Rollback: revert change; no data format change beyond ignoring GH `size` if reverted mid-way.

## Open Questions

None blocking. Factor calibration is post-ship tuning of constants without spec changes if behavior (formula shape) stays stable.
