## ADDED Requirements

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

## MODIFIED Requirements

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
