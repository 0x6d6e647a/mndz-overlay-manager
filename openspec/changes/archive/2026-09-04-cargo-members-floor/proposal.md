## Why

`cargo-floor-parity` made the plan's Cargo tag floor authoritative and split decision / build / reuse formulas, but `T(pv)` is still "first direct `rust-version` among at most three tagged files, then stop." `rust-version.workspace = true` is recognized and discarded. Cargo has no workspace MSRV: `package.rust-version` is per package, and the packages that compile for a managed ebuild are the policy package plus its local path closure, not every workspace member. Lane selection and reuse therefore authorize a rust ceiling from an incomplete local set, while full-path `Hclone` still maxes every `Cargo.toml` in the clone (including `usage` benches and xtask). That is a new check/write skew waiting on a member that declares a higher floor. Registry crates such as `kdl` remain invisible at tag time; a candidate admitted under a 1.91-sized `T` can still harvest 1.95 after fetch.

## What Changes

- **Define `T(pv)` as a named manager policy, not max-members and not Cargo-exact.** For each Cargo candidate, start at the configured policy package (`cargoPackageSubdir`, else lock root, else repository root). Resolve `rust-version.workspace = true` against that package's workspace document (`package.workspace` relative path when present, otherwise lock/repo `[workspace.package]`). Walk local path dependencies enabled by the default emerge compile set (listed `features` ∪ the dep's `default`, honor `default-features = false`, follow `dep:foo`; include normal, build, and target tables; exclude `[dev-dependencies]`). `T(pv)` is the numeric max effective rust-version over that **active** set.
- **Treat coverage states distinctly.** Complete discovery with no declared rust-version remains selection-only `"0.0.0"` with `T = Nothing`. Incomplete local discovery (unresolvable workspace doc, unreadable feature/`dep:`/`cfg`, in-tree path 404) makes the candidate ineligible for any lane and for reuse; it SHALL NOT become `"0.0.0"`. Fetch/parse/malformed failures still fail the plan. A path that normalizes outside the tagged tree, a virtual workspace with no `cargoPackageSubdir`, and a watched macos/BSD-only crate that would raise `T` above the Linux-active max each hard-fail the plan with an actionable error.
- **Keep `Hclone` on the same active set as `T`.** Recursive whole-tree clone harvest is replaced by the same policy-package path closure. `Hregistry` is unchanged. After pack, if `max(Hclone, Hregistry)` exceeds the selected rust lane ceiling, the unit hard-fails before overlay writes; the error names tag floor, harvest floor, lane ceiling, and PV.
- **Enrich the existing selected-PV snapshot.** Store aggregate floor, completeness and reasons, resolved-path provenance, and floor-policy version `2` inside the existing deps-plan payload. Non-selected candidate walks stay in memory. A valid cache hit still causes zero tagged Cargo.toml fetches. Old v1 Cargo plans miss. Go/Npm/Bun/Sbcl snapshot authority is unchanged.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `cargo-crates-assets`: replace the three-path first-direct tag floor with policy-package path-closure `T(pv)`, resolve workspace inheritance, align `Hclone` to that set, and add coverage / watched-OS / harvest-versus-ceiling fail-closed rules.
- `runtime-lanes`: Cargo candidate selection uses the member-aware tag floor; incomplete local coverage makes a candidate ineligible rather than `"0.0.0"`.
- `check-cache`: Cargo deps plans serialize coverage and provenance with policy version `2`; v1 Cargo snapshots miss; a valid hit still does not re-fetch tagged Cargo.toml.
- `deps-assets`: incomplete Cargo tag coverage cannot reuse; production apply still consumes the planned snapshot without a Cargo tag re-fetch; harvest above the selected rust ceiling hard-fails before mutation.
- `outdated-command`: decision-floor reporting uses the member-aware planned `T(pv)`; incomplete candidates are not treated as absent-floor `"0.0.0"`.
- `ensure-materialize-image`: the image rust floor for a full-path Cargo unit follows the planned member-aware tag snapshot, never the selection-only `"0.0.0"` fallback.

## Impact

- **Behavior**: `usage` (`cli/` plus path-reachable crates, not benches/xtask/shadows), `mise` (root plus `path = "crates/…"`), and `hk` (single package) get an honest tag floor for lanes and reuse. Inheritance markers resolve. Incomplete newest tags are skipped instead of admitted as 0.0.0. Escaping paths, missing package subdir on a virtual root, and macos/BSD-only crates that would raise Linux `T` hard-fail. Full-path clone harvest no longer ratchets from unrelated tree manifests. Registry harvest can still exceed `T`; that is a pre-write hard-fail, not a silent lane lie.
- **Code**: `Update.Cargo.Msrv` (inheritance, path-closure walker, coverage, target-table classification), `Update.Deps.Plan` (candidate probe and snapshot assembly), `Update.Go.Lanes` / `Update.CheckCache` (payload fields and policy key v2), `Update.Cargo.Crates` (`Hclone` set), `Update.Adequacy`, `Update.Apply.Materialize` (harvest-versus-ceiling), `Update.Materialize.Floors`. New walker types stay `other-modules`.
- **Non-goals**: no `cargo-msrv` or crates.io per-crate HTTP crawl; no max-all-workspace-members floor; no GitHub tree listing or member-glob expansion; no `default-members` as the selected package; no pycargo at a virtual workspace root; no USE flags generated from Cargo features; no separate `FloorPayload`; no making Go/Npm/Bun/Sbcl write paths authoritative in this change; no replacing `Hregistry`; no changing canonical ebuild revision semantics, partial reuse, or release-tag mutation; no CLI/config flags; no README/CONTRIBUTING/AGENTS change (new fail-closed errors are operator-facing strings only).
