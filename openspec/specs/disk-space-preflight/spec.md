# disk-space-preflight Specification

## Purpose

Estimate and gate free disk space for `update` heavy writes on the effective temp root and manager distfiles path so concurrent materialize and manifest fetches fail early with actionable messages instead of mid-write ENOSPC.

## Requirements

### Requirement: Resolve free-space check roots

The program SHALL resolve at least these paths for free-space evaluation during `update`:

1. **Effective temp root** — the directory used as the filesystem root for free-space measurement for temporary work (environment `TMPDIR` when set and usable; otherwise the process default temporary directory, typically `/tmp`). Product temporary workspace trees defined by `temp-workspace` SHALL reside under this root; free-space evaluation SHALL measure this root’s filesystem (not a separate device solely because of the `mndz/overlay-manager/<run-id>` subdirectory).
2. **Effective manager distfiles path** — as defined by `manager-distfiles` (CLI, config, or XDG default).
3. **Live Portage DISTDIR** — best-effort query of the host Portage `DISTDIR` (or the canonical system fallback when the query is unavailable), solely for optional warning when it differs from the manager path.

Free-space measurements SHALL use the free bytes available on the filesystem that backs each resolved path.

#### Scenario: TMPDIR overrides temp root

- **WHEN** `TMPDIR` is set to a usable directory on a distinct filesystem from `/tmp`
- **THEN** temp free-space evaluation uses that directory’s filesystem

#### Scenario: Manager distfiles path is always evaluated

- **WHEN** `update` runs a disk-space feasibility gate
- **THEN** free space on the effective manager distfiles path is included in hard feasibility checks

#### Scenario: Workspace subdirectory does not change the measured filesystem

- **WHEN** product temporary work will write under `<temp-root>/mndz/overlay-manager/<run-id>/` on the same filesystem as the effective temp root
- **THEN** the disk-space gate’s temp free-space check still uses the effective temp root’s filesystem free bytes

### Requirement: Disk gate units are needs-work heavy units only

The command-level disk-space feasibility gate for `update` SHALL include estimated need only for packages that **need work** under the same rules used to decide apply soft-skip vs apply (outdated GitMv; runtime-lane gaps or content/Manifest fixes for `DepsAndAssets`), and only for units that may perform **heavy** temporary materialize and/or manager distfiles fetches that require additional free space. Packages that soft-skip as up to date or already matching plan SHALL NOT contribute unit needs. Packages that hard-fail during plan or reuse/full classification (probe/API failure) SHALL NOT contribute unit needs. Work that needs only prune or overlay content edits with no heavy temp materialize and no planned missing distfile fetch SHALL NOT contribute unit needs.

#### Scenario: Bare update ignores up-to-date heavy packages

- **WHEN** the user runs `update` with no package arguments, the inventory contains multiple `DepsAndAssets` packages that do not need work, and exactly one package needs heavy full-path or reuse work
- **THEN** free-space feasibility uses only the unit need(s) for the package that needs work, not full-path estimates for the up-to-date packages

#### Scenario: Plan hard-fail excluded from gate

- **WHEN** a package needs work but reuse/full classification fails with a probe or API error for that package
- **THEN** that package does not contribute to max or concurrent-sum needs and other packages’ units are still evaluated

#### Scenario: Prune-only needs no heavy unit

- **WHEN** a `DepsAndAssets` package needs work solely for exact-set prune with no materialize and no missing distfile fetch
- **THEN** the disk-space gate does not hard-fail solely because free space would be insufficient for a hypothetical full materialize of that package

### Requirement: Reuse versus full classification for gate estimates

Before computing disk-space unit needs for a `DepsAndAssets` package that needs work and may publish or fetch assets, `update` SHALL classify each planned heavy PV unit as **reuse** or **full path** using a GitHub release asset probe after assets token and assets-path requirements for that run have been satisfied when any such package needs work.

Classification SHALL follow:

1. Matching release asset present with a usable numeric size → **reuse**; temp need from that size with the reuse expansion factor and safety margin.
2. Matching release asset present without usable size → **reuse**; baseline from Manifest same-class `DIST` size when available, otherwise the reuse ecosystem floor, then reuse factor/margin rules.
3. No release or no matching asset name → **full path**; baseline from Manifest or ecosystem full-path floor and full-path expansion factors.
4. Transport, HTTP API, or parse failure for the probe → **hard-fail that package** (not the whole command solely for that package); exclude it from gate units.
5. Unusable or missing token when assets work requires a token at hard-require time → **spine hard-fail** before classification of assets units.

Absence of a reusable asset SHALL NOT be treated as a package hard-fail; it SHALL select the full-path class.

#### Scenario: Existing asset uses reuse estimate

- **WHEN** a needs-work unit has a matching release asset with size `N`
- **THEN** the unit’s temp need is derived as a reuse estimate from `N`, not a full-path ecosystem expansion of a materialize baseline

#### Scenario: Missing asset uses full path estimate

- **WHEN** a needs-work unit has no matching release asset
- **THEN** the unit is estimated as full-path materialize for free-space feasibility

#### Scenario: Probe error hard-fails package not whole inventory gate math

- **WHEN** the release probe fails with a network or API error for one needs-work package and other packages classify successfully
- **THEN** the failing package is hard-failed and excluded from unit needs while the gate still evaluates the successful packages’ units

### Requirement: Multi-PV sequential need is max single PV

When multiple planned PVs of the same package require heavy work and those PVs materialize sequentially within the package job, the package SHALL contribute to concurrent-sum calculations using the **largest** single-PV need on that filesystem among those PVs, not the sum of all of that package’s PV needs.

#### Scenario: Three sequential full PVs count as largest

- **WHEN** one package has three sequential full-path PV units with temp needs 1 GiB, 2 GiB, and 3 GiB and no other packages need work
- **THEN** concurrent sum on temp under any `--jobs` is 3 GiB for that package’s contribution, not 6 GiB

### Requirement: Per-unit write need estimation

For each planned `update` **heavy** unit that may perform heavy disk writes (from packages that need work, after reuse vs full classification when applicable), the program SHALL compute an estimated need in bytes per relevant filesystem using the following order:

1. **Exact or near-exact size** when the unit is classified **reuse**: use GitHub release asset `size` when available, with a small expansion factor not exceeding about ten percent growth, then apply the fixed safety margin separately; when size is missing, use Manifest same-class `DIST` size or the reuse ecosystem floor as baseline under reuse rules.
2. **Baseline compressed size** for **full-path** materialize or planned distfile fetch: prefer the size field from the overlay package Manifest `DIST` line for the latest related distfile of the same asset class (vendor, deps, crates, or upstream archive); otherwise use a prior or matching GitHub release asset `size` when available.
3. **Ecosystem floor** when no baseline exists: a documented minimum reservation by ecosystem or technique class (Go full materialize, Cargo, npm/Bun, Sbcl, GitMv fetch, reuse-without-size).

Full-path materialize estimates SHALL multiply baseline compressed size by an **ecosystem expansion factor** (named product constants) to approximate peak work-tree plus simultaneous output tarball usage on the temp filesystem. Estimated need for a filesystem check SHALL then add a fixed safety margin of **256 MiB**.

The program SHALL NOT invent full-path unit estimates for packages that do not need work solely because they appear in the selected inventory.

#### Scenario: Manifest baseline for full Go path

- **WHEN** a unit will full-path materialize a Go vendor asset and the package Manifest has a `DIST` line for a prior `*-vendor.tar.xz` with a positive size
- **THEN** the temp need estimate is derived from that size times the Go expansion factor plus the 256 MiB margin

#### Scenario: Reuse uses GitHub asset size

- **WHEN** a unit will reuse an existing release asset and the release metadata includes asset `size`
- **THEN** the temp need estimate is based on that size (near-exact) plus the 256 MiB margin, not on full materialize expansion factors

#### Scenario: Missing baseline uses ecosystem floor

- **WHEN** no Manifest DIST size and no GitHub asset size are available for a full-path unit
- **THEN** the need estimate uses the ecosystem floor plus the 256 MiB margin

#### Scenario: Up-to-date package not estimated as full path

- **WHEN** a `DepsAndAssets` package is selected in inventory but does not need work
- **THEN** the disk-space gate does not include a full-path materialize need for that package

### Requirement: Already-present distfiles need no DISTDIR reservation

When estimating manager distfiles need for a planned fetch, a distfile basename that already exists under the effective manager distfiles path SHALL contribute **zero** additional bytes to that unit’s DISTDIR need for the gate (the file need not be re-downloaded).

#### Scenario: Cached vendor tarball

- **WHEN** the planned unit would fetch `pkg-1.0-vendor.tar.xz` into manager distfiles and that file already exists there
- **THEN** the manager distfiles need for that file is treated as zero for the feasibility gate

### Requirement: Concurrent feasibility under package jobs

Given the effective package job limit `N` (`--jobs`), the program SHALL compute, per filesystem (after merging same-device roots):

- **max need** — the largest single-unit need on that filesystem among planned heavy units
- **concurrent sum** — the sum of the up to `N` largest unit needs on that filesystem (units that may hold write reservations concurrently under the package job limit)

Within a single package, multi-PV full materialize that is sequential SHALL NOT count two of that package’s PVs as concurrent with each other for the concurrent sum. Distinct packages (or units that may run under different package jobs) MAY contribute concurrently up to `N`.

#### Scenario: Jobs one means concurrent sum equals max

- **WHEN** `--jobs` is `1` and multiple packages have temp needs
- **THEN** concurrent sum on temp equals the single largest unit temp need

#### Scenario: Jobs two sums two largest

- **WHEN** `--jobs` is `2` and three packages have temp needs 1 GiB, 2 GiB, and 3 GiB
- **THEN** concurrent sum on temp is 5 GiB (2 GiB + 3 GiB)

### Requirement: Same-device paths share one budget

When two hard-check paths (effective temp root and effective manager distfiles path) resolve to the same filesystem device, the program SHALL treat them as **one** free-space budget: free bytes measured once, and needs that would write to either path on that device SHALL be combined for max and concurrent-sum calculations for that device.

#### Scenario: TMPDIR under home with XDG distfiles on home

- **WHEN** temp root and manager distfiles both reside on the same device
- **THEN** the gate compares free space on that device against combined needs rather than requiring each path’s free space independently to cover only its own needs while double-counting free

### Requirement: Command-level hard fail when free space is insufficient

Before concurrent package mutation that can open heavy temp trees or perform planned distfiles fetches, `update` SHALL measure free space on each hard-check filesystem (or merged device) and **hard-fail the command** (log error, exit status `1`, no further package mutation) when either:

1. free bytes &lt; max need + applicable accounting already including the 256 MiB margin in needs, or equivalently free is less than the largest unit’s required bytes; or
2. free bytes &lt; concurrent sum for that filesystem under the effective `--jobs`.

The error message SHALL name the path or filesystem role (temp root and/or manager distfiles), report free space and required space in human-readable form, and include remediation hints that mention setting `TMPDIR` to roomier storage, freeing space, and/or lowering `--jobs`.

#### Scenario: Free below largest unit need

- **WHEN** the largest planned full-path unit requires more free temp space than is available even alone
- **THEN** `update` logs an error naming the temp root and exits with status `1` before package mutation

#### Scenario: Free above max but below concurrent sum

- **WHEN** free temp space can fit the largest unit alone but not the concurrent sum under the effective `--jobs`
- **THEN** `update` hard-fails the command with a message that indicates concurrent demand and mentions lowering `--jobs` as a remediation

### Requirement: Portage DISTDIR warn-only when distinct

When the live Portage DISTDIR path differs from the effective manager distfiles path and free space on the Portage DISTDIR filesystem is below a conservative threshold (product-defined, at least covering a small fixed margin), the program SHALL **warn** and SHALL NOT hard-fail solely for that reason.

#### Scenario: System distfiles full private path ok

- **WHEN** manager distfiles has ample free space and live Portage DISTDIR on another filesystem is very low
- **THEN** the program emits a warning about Portage DISTDIR free space and does not exit solely because of that low free space

### Requirement: Full-path admit recheck

When a unit begins full-path materialize (or another heavy temp write phase gated by this capability), the program SHALL re-measure free space on the temp filesystem and hard-fail **that unit** (not necessarily the whole command) if free space is less than that unit’s temp need, so external disk consumption after the command gate is still caught.

#### Scenario: Free space shrinks after command gate

- **WHEN** the command gate passed and later, at full-path admit for a unit, temp free space is below that unit’s need
- **THEN** that unit hard-fails with a free-space error and other packages may continue per `update-command` hard-fail aggregation rules

### Requirement: Post-clone remeasure when useful

After a shallow clone (or equivalent early tree materialization) on the full path, the program SHALL attempt to measure the work tree size when a cheap directory-size measurement is available. When a measurement is obtained, the program SHALL hard-fail the unit if measured size plus remaining phase estimate exceeds free temp space for that unit alone. When measurement is unavailable, the program SHALL continue without treating missing measurement as a spine failure (command gate and admit recheck still apply).

#### Scenario: Clone larger than remaining free

- **WHEN** after clone the measured tree plus remaining phase estimate exceeds free temp space for that unit alone
- **THEN** the unit hard-fails before continuing download or pack phases that would likely ENOSPC

### Requirement: GitHub release asset size is available for estimation

When the program parses GitHub release assets for lookup or reuse, it SHALL capture the asset byte `size` from the API payload when present so free-space estimation and reuse reservations can use it.

#### Scenario: Release JSON includes size

- **WHEN** a release asset object includes a numeric `size` field
- **THEN** that size is available to free-space estimation for the matching asset name
