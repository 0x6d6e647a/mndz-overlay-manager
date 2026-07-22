## Why

Go packages already use an end-to-end `update` path (vendor tarball, assets publish, overlay apply, runtime lanes). npm (`dev-util/openspec`) and Bun (`dev-util/ralph-tui`) still soft-skip as `Unsupported "deps assets"` even though version fetch, assets-repo seams, and overlay ebuilds already exist. Maintainers still build `-deps.tar.xz` with one-off Python helpers. Now that Go is solid, the same spine should cover npm and Bun in Haskell, with one technique model and shared runtime-lane planning.

## What Changes

- Replace `GoVendorAndAssets` with a single technique **`DepsAndAssets`** parameterized by ecosystem (`Go` | `Npm` | `Bun`) — **BREAKING** for the internal technique type and any code matching `GoVendorAndAssets`
- Implement **Haskell** deps materializers (no dependency on overlay Python scripts):
  - **Go**: existing vendor/`go-mod/` path under the new type (behavior preserved, arches generalized)
  - **Npm**: registry-only `npm pack` + populate `npm-cache/` → `{pn}-{pv}-deps.tar.xz`
  - **Bun**: GitHub clone at tag + `bun install --frozen-lockfile --cache-dir` → `bun-cache/` → `{pn}-{pv}-deps.tar.xz`
- Generalize **runtime lanes** beyond hard-coded amd64/arm64 Go: ceilings from the **runtime package’s KEYWORDS (all arches)**, plain/tilde tiers; Go uses gentoo `dev-lang/go`, Node uses gentoo `net-libs/nodejs`, Bun uses overlay `dev-lang/bun-bin`
- Candidate versions: **non-live overlay PVs ∪ upstream versions newer than max overlay PV**; no older-than-overlay backfill; no live/`9999` support; require at least one non-live local ebuild
- Lane-labeled multi-line outdated/success reporting for all `DepsAndAssets` packages
- Full overlay content from plan: parameterized assets `SRC_URI`, KEYWORDS from lanes, BDEPEND from probed req (`go.mod` / `engines.node` / `engines.bun`), Manifest adequacy, release reuse, host runtime gate on full path only
- Enable policy: `dev-util/openspec` → `DepsAndAssets Npm`; `dev-util/ralph-tui` → `DepsAndAssets Bun`; Go packages → `DepsAndAssets (Go …)`
- Leave overlay Python helper scripts in place as manual fallback (manager never invokes them)

## Capabilities

### New Capabilities

- `deps-assets`: Shared `DepsAndAssets` technique, ecosystem specs, distfile naming (`-vendor` / `-deps` by PN), materialize vs reuse spine, preflight tools, policy wiring for openspec/ralph/Go packages
- `runtime-lanes`: Generalized runtime ceiling discovery (all arches on the runtime package), candidate selection, KEYWORDS assembly, gap lines, exact-set prune; supersedes Go-only arch set
- `npm-deps-assets`: Registry-only npm cache tarball build, `engines.node` probe, `>=net-libs/nodejs-<req>[npm]` BDEPEND, gentoo nodejs ceilings, openspec apply
- `bun-deps-assets`: GitHub clone + bun-cache tarball, `engines.bun` probe, `>=dev-lang/bun-bin-<req>` BDEPEND, overlay bun-bin ceilings, ralph-tui apply

### Modified Capabilities

- `go-vendor-assets`: Technique identity becomes `DepsAndAssets (Go …)`; keep vendor layout, publish-before-overlay, BDEPEND/Manifest/reuse rules; arch/lane behavior deferred to `runtime-lanes`
- `go-tree-lanes`: Requirements move to / align with `runtime-lanes` (all runtime arches, shared candidate rule); Go-specific ceiling source remains gentoo `dev-lang/go`
- `assets-publish`: Confirm non-Go `-deps` filename and release asset paths (already forward-compatible; tighten if gaps remain)
- `update-apply`: Dispatch `DepsAndAssets` for Go/Npm/Bun; `techniqueNeedsAssets` covers all three; retire `GoVendorAndAssets` constructor
- `update-command` / `outdated-command` / `cli-help`: Preflight for `npm`/`bun` when in scope; lane-labeled reporting for npm/Bun; help/docs mention deps techniques
- `project-docs`: README/CONTRIBUTING/AGENTS for new tools (npm, bun) and technique model when operator-facing behavior changes

## Impact

- **Code**: `Update.Types`, `Update.Hardcoded`, `Update.Apply`, `Update.Check`, `Update.Preflight`, `Update.EbuildEdit`, `Update.Assets.Layout`, `Update.Go.*` (migrate under deps/runtime-lanes), new npm/bun materializer modules; tests/fixtures for engines parse, multi-arch ceilings, npm/bun naming
- **External tools**: existing `go`, `xz`, plus **`npm`** and **`bun`** on full-path materialize; reuse path still needs no host language tool
- **Runtime trees**: gentoo `dev-lang/go`, gentoo `net-libs/nodejs`, overlay `dev-lang/bun-bin` for ceilings
- **Packages**: `dolt`/`beads`/`crush` (type migrate + multi-arch KEYWORDS), `openspec`, `ralph-tui` leave Unsupported
- **Non-goals**: live ebuilds; first-import empty package dirs; npm git-only clone; cargo CRATES; complex semver `engines` ranges; deleting overlay Python scripts; overlay auto-push
