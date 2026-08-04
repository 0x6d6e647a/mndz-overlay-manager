# disk-space-preflight Specification

## Purpose

Estimate and gate free disk space for `update` heavy writes on the effective temp root and manager distfiles path so concurrent materialize and manifest fetches fail early with actionable messages instead of mid-write ENOSPC.

## Requirements

### Requirement: Resolve free-space check roots

The program SHALL resolve at least these paths for free-space evaluation during `update`:

1. **Effective temp root** — the directory used for system temporary directories (environment `TMPDIR` when set and usable; otherwise the process default temporary directory, typically `/tmp`).
2. **Effective manager distfiles path** — as defined by `manager-distfiles` (CLI, config, or XDG default).
3. **Live Portage DISTDIR** — best-effort query of the host Portage `DISTDIR` (or the canonical system fallback when the query is unavailable), solely for optional warning when it differs from the manager path.

Free-space measurements SHALL use the free bytes available on the filesystem that backs each resolved path.

#### Scenario: TMPDIR overrides temp root

- **WHEN** `TMPDIR` is set to a usable directory on a distinct filesystem from `/tmp`
- **THEN** temp free-space evaluation uses that directory’s filesystem

#### Scenario: Manager distfiles path is always evaluated

- **WHEN** `update` runs a disk-space feasibility gate
- **THEN** free space on the effective manager distfiles path is included in hard feasibility checks

### Requirement: Per-unit write need estimation

For each planned `update` unit that may perform heavy disk writes, the program SHALL compute an estimated need in bytes per relevant filesystem using the following order:

1. **Exact or near-exact size** when the unit will only download known assets (reuse path): use GitHub release asset `size` when available, with a small expansion factor not exceeding about ten percent growth, then apply the fixed safety margin separately.
2. **Baseline compressed size** for full-path materialize or planned distfile fetch: prefer the size field from the overlay package Manifest `DIST` line for the latest related distfile of the same asset class (vendor, deps, crates, or upstream archive); otherwise use a prior or matching GitHub release asset `size` when available.
3. **Ecosystem floor** when no baseline exists: a documented minimum reservation by ecosystem or technique class (Go full materialize, Cargo, npm/Bun, Sbcl, GitMv fetch, reuse-without-size).

Full-path materialize estimates SHALL multiply baseline compressed size by an **ecosystem expansion factor** (named product constants) to approximate peak work-tree plus simultaneous output tarball usage on the temp filesystem. Estimated need for a filesystem check SHALL then add a fixed safety margin of **256 MiB**.

#### Scenario: Manifest baseline for full Go path

- **WHEN** a unit will full-path materialize a Go vendor asset and the package Manifest has a `DIST` line for a prior `*-vendor.tar.xz` with a positive size
- **THEN** the temp need estimate is derived from that size times the Go expansion factor plus the 256 MiB margin

#### Scenario: Reuse uses GitHub asset size

- **WHEN** a unit will reuse an existing release asset and the release metadata includes asset `size`
- **THEN** the temp need estimate is based on that size (near-exact) plus the 256 MiB margin, not on full materialize expansion factors

#### Scenario: Missing baseline uses ecosystem floor

- **WHEN** no Manifest DIST size and no GitHub asset size are available for a full-path unit
- **THEN** the need estimate uses the ecosystem floor plus the 256 MiB margin

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
