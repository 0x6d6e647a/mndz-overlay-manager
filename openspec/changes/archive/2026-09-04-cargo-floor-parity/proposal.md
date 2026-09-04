## Why

`dev-util/usage` reports `6.4.1 -> 6.4.1` (content-only, `[assets reusable]`) on every `outdated` run immediately after `update` writes that same version: the check and the write derive the Cargo `RUST_MIN_VER` floor from different facts (check probes only the configured member `Cargo.toml` → 1.91; the materializer writes `max(root, in-tree rust-version walk, donor)` carried from the last real build → 1.95). The runtimes disagree, so the overlay never reaches a steady "current" state.

The 1.95 figure is not computed by `pycargoebuild`. Overlay `usage` ebuilds carry a human comment `# kdl@6.7.1 requires rust-version 1.95`; a local inplace spike on pycargoebuild 0.16.0 (same version as the materialize image) prints `The in-place mode updates CRATES, GIT_CRATES and crate LICENSE+= variables only, other metadata is left unchanged` and leaves `RUST_MIN_VER` untouched. The living cargo spec already asked for max `package.rust-version` among lock packages **after crate fetch**, but the implementation walks only the git clone, so registry crates such as `kdl` are never seen. Donor carry is the only reason 1.95 survives, and the same split also lets a donor-less write silently lower a floor.

## What Changes

- **Make the plan's Cargo tag-floor snapshot authoritative.** For each selected PV, one ordered package -> lock root -> repository root probe reads direct `[package].rust-version` and `[workspace.package].rust-version` fields with table-aware TOML parsing. The probe order is deduplicated, parse/transport failures fail closed, and complete absence is preserved in the plan separately from the lane candidate's `"0.0.0"` selection fallback. Check, materialize-image planning, reuse writing, and apply consume that stored snapshot instead of re-fetching the tag.
- **Use one canonical ebuild inventory rule.** For a present PV, the highest numeric Gentoo revision among non-live same-PV ebuilds is authoritative for content assessment, the same-PV donor, and template selection. When the PV is absent, the fallback template is the highest non-live local ebuild from the plan's initial inventory, regardless of whether it is below or above the target.
- **Split the Cargo floor into two explicit rules plus a distinct reuse-write rule:**
  - *Decision floor* (content adequacy and soft-skip): `max(tag floor snapshot, canonical same-PV RUST_MIN_VER)`. Adequacy is **at or above** that floor (too-low only), so a written 1.95 against a 1.91 tag floor is not a content fix. If neither operand is usable, the PV needs work and must use the full path; an absent floor never means adequate.
  - *Build floor* (full-path materialize): harvest is the maximum direct Rust declaration among (1) recursively discovered clone/lock-tree manifests and (2) the package-root `Cargo.toml` of each extracted registry crate under pack stage `cargo_home/gentoo/{name}-{version}/`. Harvest is **not** `RUST_MIN_VER` parsed from pycargo's inplace ebuild. A version bump writes `max(tag, harvest)`; a same-PV rewrite writes `max(tag, canonical same-PV floor, harvest)`. If every applicable operand is absent after harvest, the unit hard-fails before overlay writes.
  - *Reuse-write floor*: `max(tag floor snapshot, RUST_MIN_VER of the canonical selected template)`. Reuse never harvests crates. If neither operand is usable, release assets do not make the unit reusable and planning forces the full path. A reuse bump may carry a conservative-high fallback floor indefinitely; only an independently required later full path can recompute it.
- **Replace Boolean content classification with one shared assessment** for `outdated`, update planning, and the direct apply entry. The assessment records both PVs that need work and PVs that must bypass release reuse; production apply consumes the plan result without reclassification.
- **Make asset completeness exact and unit-wide.** Manifest adequacy requires an exact `DIST` filename token for every primary and companion distfile. A unit is `[assets reusable]` only when every required release asset is usable. A missing release takes the full path; an existing partial release, or an existing complete release for a forced-full unit, hard-fails because the manager does not mutate/delete existing release tags.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `cargo-crates-assets`: the `MSRV probe and RUST_MIN_VER` requirement is rewritten into decision-floor / build-floor / reuse-write-floor rules, with crate-manifest harvest after fetch and bump-vs-same-PV ratchet semantics.
- `outdated-command`: content adequacy uses the canonical ebuild and authoritative plan snapshot, reports unknown-floor PVs as work, and requires all-assets reuse plus exact companion-aware Manifest completeness.
- `deps-assets`: one plan-time assessment is shared by outdated/update behavior, carries forced-full PVs into apply, and makes release/Manifest completeness companion-aware.
- `check-cache`: cached Cargo runtime-lane plans retain selected direct tag-floor snapshots; old Cargo plans lacking them miss instead of triggering apply-time re-probes.
- `assets-publish`: an existing release tag that cannot be reused blocks full publication and hard-fails without automatic release mutation.
- `disk-space-preflight`: reuse/full estimates honor forced-full status and exclude existing-tag publication conflicts as package hard failures.
- `go-vendor-assets`: an existing tag missing its vendor asset is a release conflict, not an automatically publishable missing release.

## Impact

- **Behavior**: the perpetual `usage 6.4.1 -> 6.4.1` false positive goes away; full-path bumps write the crate-derived floor (so `kdl` 1.95 is discovered without a human comment, and a genuine drop is possible); no-signal units cannot soft-skip or reuse unsafely; `outdated` flags exact missing companion Manifest entries and labels assets reusable only when release lookup confirms the complete unit; existing release tags that require full publication fail with actionable guidance.
- **Code**: `Update/Check.hs` and its CLI dependency plumbing, lane-plan/cache serialization, materialize-image floor lookup, `Update/Apply/Materialize.hs`, `Update/Apply/Plan.hs`, `Update/Apply/OverlayWrite.hs`, `Update/Cargo/Crates.hs`, `Update/Cargo/Msrv.hs`, `Update/EbuildEdit.hs`, and shared Manifest/disk-preflight consumers; new internal shared adequacy and canonical ebuild-selection modules (`other-modules`, not public API).
- **Non-goals**: no crates.io HTTP per-crate MSRV crawl or `cargo-msrv` binary; no full `rust-version.workspace = true` resolution, workspace member/path dependency graph, glob expansion, or separate persisted `FloorPayload` cache (the selected direct tag floor is stored in the existing deps plan and can be enriched by `cargo-members-floor`); no exact Cargo dependency-graph harvest; no update, replacement, or deletion of a release tag that pre-existed full publication; no partial release repair/reuse; no new CLI flags; no change to GitMv or non-Cargo runtime floor rules; no automatic re-harvest solely to lower a conservative reuse floor; no invented per-crate `RUST_MIN_VER` comments. Existing-tag conflict and exact Manifest/all-assets behavior apply uniformly where shared `DepsAndAssets` release logic applies.
