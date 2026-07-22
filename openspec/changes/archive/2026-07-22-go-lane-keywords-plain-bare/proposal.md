## Why

Go tree-lane planning already selects package PVs from Gentoo `dev-lang/go` plain vs tilde ceilings, but overlay KEYWORDS are always written as `~arch`. That means a package version chosen for a **plain** go lane is never keyworded stable, so stable Portage profiles (`ACCEPT_KEYWORDS="amd64"` / `arm64`) have no real candidate even when stable go can build that version. Plain lanes are therefore only half-real: version selection follows stable go, but package visibility does not.

## What Changes

- Change KEYWORDS assembly so membership reflects **lane tier**, not only arch presence:
  - If any **plain** lane for an arch targets a PV → emit bare `arch` (e.g. `amd64`).
  - Else if any **tilde** lane for that arch targets the PV → emit `~arch`.
  - Never emit both bare and tilde for the same arch on one ebuild.
- Treat bare package KEYWORDS as covering both plain and tilde consumers on that arch (same implication already used for go ceilings: bare go satisfies the tilde ceiling).
- **BREAKING** (overlay output): existing `GoVendorAndAssets` ebuilds that today have only `~amd64` / `~arm64` while plain lanes target them will be content-fixed (often revbumped) to bare keywords; multi-PV sets may shrink when go is fully stable on an arch and older tips are pruned.
- Update tests, outdated/apply content-fix matching, and docs that assert “KEYWORDS tilde only.”

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `go-tree-lanes`: KEYWORDS assembly requirement — plain→bare, tilde-only→`~`, bare covers both; scenarios for collapse and arch divergence.
- `go-vendor-assets`: overlay KEYWORDS for multi-PV Go packages — drop “tilde only” rule; match planned bare/`~` membership.
- `update-apply`: apply sets planned KEYWORDS (including bare tokens when plain lanes target the PV); revise the “KEYWORDS tilde only” scenario.

## Impact

- **Code**: `Update.Go.Lanes` (`assembleKeywords` / collapse), apply overlay rewrite and content-fix equality, unit tests in `test/Main.hs`.
- **Specs**: deltas for the capabilities above.
- **Runtime overlay**: re-running `update` on packages such as `dev-util/crush` after go-1.26.4 is stable on both arches should converge toward a single tip with `KEYWORDS="amd64 arm64"` (example) rather than `~amd64 ~arm64` plus leftover older PVs with incomplete arch membership.
- **No** change to go ceiling discovery, go.mod probing, vendor/assets publish paths, or host Go gate — only how planned KEYWORDS tokens are derived and written.
