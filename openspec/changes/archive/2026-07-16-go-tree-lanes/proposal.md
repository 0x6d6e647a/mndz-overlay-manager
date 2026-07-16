## Why

`GoVendorAndAssets` packages currently update only to upstream latest. When that tag’s `go.mod` requires a newer Go than Gentoo’s `dev-lang/go` provides for a keyword/arch, apply hard-fails (or would ship a BDEPEND consumers cannot satisfy). Overlay users on different arches and keyword tiers need up to several compatible package PVs—selected from the Gentoo tree’s Go ceilings, not the maintainer’s host toolchain—so Portage can resolve the newest package whose Go BDEPEND their installed Go can meet.

## What Changes

- Add a **Go tree-lane planner** for every `GoVendorAndAssets` package that:
  - Discovers Gentoo `dev-lang/go` ceilings via `portageq get_repo_path / gentoo` and ebuild KEYWORDS (no config tree override)
  - Builds up to **four lanes**: `{amd64, arm64} × {plain keyword, ~keyword}` for `dev-lang/go`
  - Probes upstream tags for the package’s `go.mod` `go` line and picks the newest package PV with `go_req ≤` each lane’s Go ceiling
  - Collapses to unique ebuild PVs (at most four); one PV when all lanes agree
- **`outdated` and `update` share the planner** for Go packages (no longer single newest-local vs single latest-only)
- **`update` applies all lane targets**: vendor/assets per needed PV, write ebuilds with overlay `~` KEYWORDS scoped by arch membership, BDEPEND from that PV’s `go.mod`, **exact-set package dir** (delete historical ebuilds not in the target set), Manifest, **one signed commit per lane** (coalesce when two lanes share one PV write)
- Stdout / outdated lines use labels `(dev-lang/go amd64)`, `(dev-lang/go ~amd64)`, `(dev-lang/go arm64)`, `(dev-lang/go ~arm64)`; split/converge mapping of old locals → new targets on separate lines
- Host Go remains apply-time gate only (not a selection input); operator should run ~ tree Go so all vendor builds can succeed
- Non-Go techniques stay latest-only; no host-based dual matrix; no `GOTOOLCHAIN=auto`; `--version` pin is out of scope for this change

## Capabilities

### New Capabilities

- `go-tree-lanes`: Plan and apply multi-PV maintenance for `GoVendorAndAssets` packages from Gentoo `dev-lang/go` keyword/arch ceilings and upstream `go.mod` requirements; exact-set ebuild convergence; lane-labeled reporting

### Modified Capabilities

- `outdated-command`: For Go vendor packages, report per-lane gaps using the shared planner and lane labels (not only local newest vs upstream latest)
- `update-command`: For Go vendor packages, select and apply planner targets (multi-lane, multi-commit); update success stdout for split/converge and lane labels; bulk selection uses planner gaps
- `update-apply`: Multi-target apply for `GoVendorAndAssets` (per-PV vendor publish, KEYWORDS assembly, prune non-target ebuilds, per-lane commits)
- `go-vendor-assets`: Integrate tree-lane target PVs into clone/vendor/BDEPEND path; document exact-set and KEYWORDS `~arch` rules for multi-PV packages
- `update-source`: Support listing upstream version candidates (paginated tags/releases) needed for range selection, not only latest

## Impact

- **Code**: New planner module(s) (tree Go ceilings, go.mod-at-ref probe, lane selection); extend `Update.GitHub` for version lists; wire `Update.Check` / `outdated` and `Update.Apply` / `update` through the planner for `GoVendorAndAssets`; ebuild KEYWORDS + delete extras; CLI stdout formatting
- **Ops**: `update` / `outdated` for dolt, beads, crush (and future Go vendor policies) maintain ≤4 ebuilds driven by gentoo tree + upstream; requires `portageq` and a readable gentoo repo; host Go ≥ highest `go_req` among targets to vendor all
- **Specs**: New `go-tree-lanes`; deltas on outdated, update-command, update-apply, go-vendor-assets, update-source
- **Non-goals**: Config override for Portage tree path; host-Go selection; bare stable KEYWORDS on overlay packages; non-amd64/arm64 arches; explicit `--version` CLI
