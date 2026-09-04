## Context

Cargo adequacy currently uses two independent disk views and two independent tag probes. `Update.Check.contentFixPVs` selects the first same-PV `Ebuild` from discovery and probes tagged `Cargo.toml` files without a donor. `Update.Apply.Materialize.contentFixNeededEnv` performs an unsorted filename scan and combines a separately fetched tag value with that selected file's `RUST_MIN_VER`. Full materialization combines a policy-package value, a recursive clone-tree walk, and a template donor even on version bumps. These paths can classify or write the same PV differently.

`dev-util/usage` exposes the resulting loop: the tagged package manifest declares Rust 1.91, while the overlay correctly carries 1.95 because registry crate `kdl` declares that floor. Check expects exact equality with 1.91 and repeatedly reports `6.4.1 -> 6.4.1`; apply preserves 1.95. Pycargoebuild 0.16.0 does not compute this field: its inplace mode rewrites crates and license variables while leaving `RUST_MIN_VER` from the template unchanged. Therefore pycargo's working ebuild cannot be harvest evidence.

The existing full path extracts registry `.crate` files under `stage/cargo_home/gentoo/{name}-{version}/`, but the floor walker only scans the cloned source tree. The fetched registry package-root manifests are available before overlay mutation and can provide the missing `kdl` declaration.

The runtime-lane plan and its existing `DepsPayload` cache already carry the selected per-lane runtime requirement. Production apply consumes this plan without re-planning, but content assessment and Cargo reuse currently re-fetch tagged metadata. This change makes one selected-PV tag-floor snapshot authoritative through check, plan, cache, image-floor derivation, and apply.

## Goals / Non-Goals

**Goals:**

- Eliminate Cargo write/check loops by making the plan snapshot, canonical same-PV ebuild, and written-floor rules explicit.
- Select one authoritative non-live same-PV ebuild by numeric Gentoo revision, independent of directory or discovery order.
- Parse direct Cargo Rust declarations table-aware and distinguish a complete absence from fetch/TOML failure.
- Carry the direct tag-floor result in the existing runtime-lane plan/cache so production apply does not re-fetch it.
- Route a unit to full materialization when the reuse path cannot derive a floor, then hard-fail without overlay writes if harvest still yields no floor.
- Harvest direct Rust declarations from the recursive clone tree and package-root manifests of extracted registry crates.
- Use one content assessment for outdated/update planning and the direct apply entry, with production apply consuming the planned result.
- Require exact Manifest `DIST` names and every required primary/companion release asset for reuse.

**Non-Goals:**

- No `cargo-msrv` execution or crates.io per-crate HTTP crawl.
- No full `rust-version.workspace = true` resolution, workspace-member/path dependency closure, member-glob expansion, or virtual-workspace support; those remain `cargo-members-floor` scope.
- No exact Cargo dependency-graph harvest; the clone half remains a conservative recursive source-tree scan.
- No separate persisted `FloorPayload`; the selected direct floor extends the existing deps plan payload.
- No automatic full materialization solely to lower a conservative-high reuse floor.
- No partial release-asset reuse; no update, replacement, or deletion of existing release tags; no new CLI/config flags, GitMv changes, or new floor rules for Go/Npm/Bun/Sbcl.
- No generated per-crate comments around `RUST_MIN_VER`.

## Decisions

### D1. Canonical ebuild inventory

For one bare PV, the authoritative ebuild is the non-live same-PV file with the highest numeric Gentoo revision. A bare filename is revision zero; `-r1`, `-r2`, and later revisions are ordered numerically, not lexically. Live versions such as `9999` never participate.

The authoritative file supplies:

- the ebuild content assessed for adequacy;
- the same-PV donor `RUST_MIN_VER`;
- the same-PV full-path existing-floor operand;
- the same-PV reuse template.

When there is no same-PV file, the template fallback is the highest non-live local ebuild selected from the plan's initial inventory, then its highest revision. It may be above or below the target PV; this preserves runtime-lane backfills. Units do not rescan newly written cross-PV files to replace that planned fallback. If candidates that matter cannot be ordered, the package fails closed rather than using filesystem order.

A cycle-safe internal leaf module, `Update.EbuildSelection`, owns this ordering and selection. Check, direct apply, and `findTemplate` use it; no caller maintains a parallel first-match rule.

### D2. One direct tag-floor probe and authoritative snapshot

For a Cargo candidate, the ordered probe locations are:

1. effective package path: `cargoPackageSubdir <|> cargoLockSubdir`;
2. lock path: `cargoLockSubdir`;
3. repository root.

Duplicate paths are removed while preserving this order. At each fetched Cargo.toml, table-aware TOML parsing checks direct `[package].rust-version`, then direct `[workspace.package].rust-version`. The first valid declaration in probe order is normalized to three components and becomes the tag floor. A valid `rust-version.workspace = true` marker is not a malformed direct value; it contributes no direct floor and probing continues. Workspace inheritance and member relevance are not resolved here.

Expected path absence continues to the next location. Transport/auth/server failures, unreadable responses, malformed TOML, and malformed present Rust-version values fail the plan; they are not converted to an absent declaration. If every reachable probe location is valid but has no direct declaration, the result is an explicit absent floor.

The selected result is stored per planned Cargo PV in `RuntimeLanePlan` (exact representation is internal) and serialized inside the existing `DepsPayload`. It preserves `Just normalizedFloor` versus direct-floor absence. Cargo candidate selection alone maps absence to `"0.0.0"`; adequacy, write, and image planning consume the raw snapshot and never treat that fallback as a declared floor.

A valid cached Cargo plan must contain the selected-PV snapshots. A pre-change Cargo deps entry without them is a cache miss; non-Cargo entries remain usable. The cache document schema can remain version one with an optional plan field, but newly stored Cargo plans always include it. The Cargo plan-policy fingerprint includes source prefix and Cargo package/lock paths so changed probe policy cannot reuse a stale floor.

### D3. Shared assessment carries needs-work and forced-full PVs

The shared result is conceptually:

```text
ContentAssessment
    needsWorkPVs :: [PV]
    forceFullPVs :: [PV]
```

For a present planned PV, `Update.Adequacy` receives the canonical ebuild content, planned requirement snapshot, expected keywords, package directory, and required asset names. It performs no upstream fetch. It returns one of:

```text
Adequate
NeedsRewrite
NeedsFull
```

`NeedsFull` also implies needs-work. For Cargo, it is selected when neither the planned tag floor nor the canonical same-PV ebuild contains a usable floor. Missing or malformed local `RUST_MIN_VER` is content needing repair; it is never trusted as a donor. When a valid tag floor exists, a missing local floor can be repaired through reuse. When no tag floor exists, the unit requires harvest and therefore the full path.

For every missing or content-fix PV, planning also computes the reuse-write floor from the planned tag floor and canonical selected template. If neither operand is usable, that PV is forced full even when all release assets exist. This covers missing-PV bumps as well as present-PV repairs.

Update planning stores both sets and the canonical initial-inventory template selections in `PlannedDeps` (or one equivalent in-memory plan structure). Selection and assessment expose an error channel so incomparable/retrieval failures become package check/plan/apply failures rather than arbitrary choices. Release classification and the actual materialize path both honor `forceFullPVs`; they do not merely estimate full and then choose reuse during mutation. Classification attaches `ExpectedReuse` or `ExpectedFull` to each admitted PV and carries those routes, including withheld-wave reclassification results, into mutation. Mutation revalidates the expected route: reuse must remain complete and full must remain tag-absent. A mismatch or lookup error hard-fails instead of switching route after disk/image admission. Production apply consumes these planned sets without content reclassification. For Cargo, it also consumes the selected tag-floor snapshot without a tag re-fetch; this change does not require removing later write-time requirement fetches for other ecosystems. The direct plan-and-apply entry calls the same assessment and classification once. The legacy Go-only `contentFixNeeded` test wrapper may continue returning only `needsWorkPVs` to avoid unrelated test churn.

### D4. Three floor rules

Let:

```text
T(pv) = planned direct tag-floor snapshot
D(pv) = RUST_MIN_VER from the canonical same-PV ebuild
Hclone = direct Rust declarations found by recursive clone-tree harvest
Hregistry = direct Rust declarations from extracted registry package roots
Ftemplate = RUST_MIN_VER from the canonical selected template
```

The decision floor for a present PV is:

```text
max(T(pv), D(pv))
```

Adequacy is too-low-only: normalized written `RUST_MIN_VER >= decision floor`. A conservative-high floor is adequate. If both operands are absent or unusable, the PV is `NeedsFull`, not adequate.

The full-path build floor is:

```text
bump:            max(T(pv), Hclone, Hregistry)
same-PV rewrite: max(T(pv), D(pv), Hclone, Hregistry)
```

The tag snapshot is an operand on both paths, so the next decision floor cannot exceed a just-written floor. A previous-PV fallback is template content but is not a floor operand on a full-path bump. If all applicable operands are absent after packing, the unit hard-fails before ebuild, Manifest, asset publication, or commit mutation.

The reuse-write floor is:

```text
max(T(pv), Ftemplate)
```

Reuse performs no clone, pycargo, or crate harvest. A previous/other-PV fallback can therefore preserve a conservative-high floor on a bump. That value may persist indefinitely because too-low-only adequacy will not schedule a correction. If an independently required full path later runs, it recomputes from its own operands; no automatic correction is promised.

All comparisons and writes use numeric three-component normalization. Text ordering is forbidden (`1.100` must compare above `1.99`).

### D5. Hybrid table-aware harvest

After pycargo and crate packing have succeeded:

1. Recursively scan Cargo.toml files under the cloned lock/source root, retaining the existing exclusions for build/cache directories.
2. Enumerate the immediate extracted registry package directories under `stage/cargo_home/gentoo/` and inspect only each package-root `Cargo.toml`; do not recursively include examples or fixtures nested inside a registry crate.
3. Parse direct `[package].rust-version` and direct `[workspace.package].rust-version` table-aware and take the numeric maximum across both sets.

A malformed harvested Cargo.toml or malformed present direct Rust-version value hard-fails the unit; harvest does not silently skip malformed facts. A valid workspace-inheritance marker remains an absent direct value in this change.

The clone scan is intentionally location-based and conservative, not an exact Cargo dependency closure. Registry root-only scanning avoids unrelated nested manifests while covering the `kdl` case. Git dependencies outside the clone and registry stage, inherited member declarations, and crates without declared floors remain known limitations.

Pycargo's working ebuild `RUST_MIN_VER` is not read as harvest input. It is template residue and cannot establish crate requirements.

### D6. Template selection and write plumbing

`findTemplate` returns path plus whether the canonical result is same-PV. Its same-PV lookup uses `Update.EbuildSelection`; its supplied bump fallback is the canonical path captured from the initial plan inventory.

There are three call sites:

1. full Cargo materialization, which passes `D(pv)` only when same-PV;
2. Cargo reuse, which uses `Ftemplate` regardless of same-PV versus fallback;
3. `overlayAfterAssets`, which needs the canonical path for template content.

The full Cargo result and reuse branch each produce one final `Maybe Text` floor. `OverlayWrite.ensureRustMinVer` receives that value as the sole intended assignment and replaces stale donor text, including a full bump that legitimately drops from 1.95 to 1.91.

### D7. All-assets reuse and exact Manifest records

`requiredAssetBasenames` is centralized once and returns the ecosystem primary tarball plus policy-required companions such as opencode models.

Release reuse is unit-wide:

```text
reusable iff the release tag exists,
            every required basename has a usable release asset,
            and the PV is not force-full
```

If no release tag exists, full publication is allowed. If initial classification sees a partial release, or sees a release for a forced-full PV, the package hard-fails before disk/image admission with the owner/repository/tag and guidance to remove or repair the release externally. Mutation rechecks the planned route before beginning that PV's local/remote publication or overlay mutation; a changed route hard-fails rather than switching. This lookup cannot atomically reserve a GitHub tag: a tag created by another actor after the recheck may still make release creation fail after assets-repository work, using existing partial-success diagnostics. The manager does not upload to, replace, or delete a release that pre-existed this full-publication attempt. Existing best-effort deletion of a release created by the current attempt after upload failure remains unchanged. `[assets reusable]` is emitted only for a needs-work unit whose release lookup confirms the complete reusable condition; outdated release-lookup failure conservatively suppresses the optional marker without hiding the needs-work line. Partial reuse remains out of scope.

Manifest adequacy parses records as tokens. A required basename is present only when the first token is exactly `DIST` and the second token is exactly that basename. Substrings and sidecars do not match. Post-write SHA512 lookup uses the same exact record selection; conflicting duplicate exact records fail rather than selecting arbitrarily. Planning checks exact presence, while materialization retains size/digest verification.

### D8. Sequence of calls

```text
outdated / update plan:
    build or load RuntimeLanePlan
        Cargo live plan probes direct tag floor once per candidate
        selected PV snapshots are stored in the plan/cache
    select canonical same-PV ebuild from initial inventory
    assess present planned PVs through Update.Adequacy
    derive needsWorkPVs and forceFullPVs
    outdated optionally probes the release to prove the all-assets marker
        lookup failure suppresses the marker but not the needs-work line
    update classifies complete+not-forced as ExpectedReuse
        missing tag -> ExpectedFull
        existing partial tag or existing tag+forced-full -> package hard-fail
    carry admitted per-PV routes through disk/image gate and withheld waves

production update apply:
    consume RuntimeLanePlan + needsWorkPVs + forceFullPVs + expected routes
    do not reclassify content; Cargo does not re-fetch the tag floor
    revalidate route immediately before the PV unit
        ExpectedReuse must remain complete
        ExpectedFull must remain tag-absent
        mismatch/error -> hard-fail, never switch route

direct plan-and-apply entry:
    obtain the same plan snapshot
    invoke the same assessment once
    pass both planned sets into mutation

full Cargo PV:
    canonical template -> clone + pycargo + pack
    harvest clone recursively + extracted registry package roots
    compute build floor -> ensureRustMinVer -> exact Manifest verification

reuse Cargo PV:
    require all release assets and non-forced-full plan
    canonical template + stored tag floor -> reuse-write floor
    download all assets -> ensureRustMinVer -> exact Manifest verification
```

### D9. Module and dependency boundaries

- `Update.EbuildSelection` is an internal leaf over overlay ebuild/version types and owns canonical non-live ordering.
- `Update.Cargo.Msrv` owns table-aware direct parsing, numeric normalization/max, and a callback-parameterized ordered tag probe. It does not import `Update.Deps.Plan`.
- `Update.Adequacy` owns `ContentAssessment`, shared content predicates, required asset basenames, exact Manifest presence, and Cargo decision/reuse feasibility from already planned facts. It does not fetch remote metadata.
- A cycle-safe internal Manifest record module owns exact `DIST` token parsing for adequacy, digest selection, disk baselines, and preflight consumers.
- `Update.Deps.Plan` constructs and stores selected tag-floor snapshots.
- `Update.Check` and direct apply become wrappers over the shared assessment rather than owners of Cargo probes or ebuild selection.
- New modules remain `other-modules`; do not expand the public library surface solely for tests.

### D10. Cache compatibility

The existing deps plan is already the cache payload intended to make apply independent of upstream re-listing and per-PV probes. Extending it is preferable to a second cache namespace.

New Cargo plans serialize their selected direct-floor snapshots. A cached Cargo plan lacking those snapshots is treated as a miss and replaced after a successful live plan. Existing non-Cargo plans remain decodable and usable. Cache validity also incorporates the tag prefix and Cargo package/lock path policy that produced the snapshots. Donor floors are never cached as tag facts; local ebuild/Manifest fingerprints continue invalidating overlay-state changes.

## Risks / Trade-offs

- Direct table-aware parsing still does not resolve `rust-version.workspace = true`; the ordered workspace-root declaration is a conservative direct fallback, not proof that the policy package inherits it. `cargo-members-floor` owns effective inheritance and relevant-member semantics.
- Candidate selection retains `"0.0.0"` for complete direct-floor absence. A later clone harvest can discover a higher floor than tag-time selection knew. Member-aware lane completeness and late floor-versus-lane verification remain follow-up questions; this change at least prevents unsafe reuse and soft-skip.
- Recursive clone harvest can include unrelated source-tree examples or fixtures and remain conservative-high. Exact dependency closure is out of scope.
- Git crates not present under the clone root or registry stage and crates without `rust-version` remain invisible.
- Conservative-high reuse floors may persist indefinitely. This is safe but can over-constrain the ebuild.
- A partial existing release or complete release whose PV is forced full hard-fails until the operator removes or repairs that release externally. This avoids intentional non-atomic remote mutation but cannot reserve a tag against an external creation race after recheck.
- Adding selected snapshots to the cached plan requires JSON compatibility tests and a deliberate miss for old Cargo entries.
- Canonical revision ordering changes behavior in directories with multiple same-PV revisions; the highest revision now consistently wins rather than arbitrary filesystem order.
- Existing tests that construct `RuntimeLanePlan` or `PlannedDeps` directly will require fixture updates. Keep compatibility wrappers only where they avoid unrelated public/test churn; do not retain parallel production logic.

## Migration Plan

- Internal behavior and cache payload only; there are no CLI or configuration changes.
- Old Cargo deps cache entries without selected-floor snapshots become misses. They are safely replaced by live planning; the cache document need not be deleted manually.
- Overlay files are untouched until apply. The first full Cargo run may raise a root-only floor from registry harvest or drop a previous-PV-only donor floor on a bump. Same-PV rewrites remain monotonic relative to the authoritative revision.
- Release tags observed before a full-publication attempt are never mutated automatically. Initial conflicts fail before disk/image admission; route changes observed at unit recheck fail before that unit's mutation. Best-effort rollback deletion remains allowed only for a release created by the current failed publication.
- Existing human comments around `RUST_MIN_VER` remain untouched and may become stale if a full bump legitimately lowers the assignment.
- README/CONTRIBUTING/AGENTS changes are not expected unless implementation exposes new operator diagnostics or changes tooling.
- Delta specs remain under the change until OpenSpec sync/archive; implementation does not manually copy them into living specs.
- Rollback may cause new Cargo plan cache fields to be ignored or decoded as a miss; floors already written remain valid conservative constraints.

## Open Questions

No unresolved question blocks this change after the locked decisions above. Full Cargo workspace inheritance, relevant-member selection, member globs/excludes, virtual roots, member-aware lane completeness, and enrichment of the selected snapshot are explicitly deferred to the separate `cargo-members-floor` exploration.
