# Proposal: crates.io-sourced Cargo packages and dev-util/biodiff seed

## Why

The overlay wants `dev-util/biodiff` (Rust binary hex-diff tool, upstream `8051Enthusiast/biodiff`). Its git-tag source tree cannot build with default features: `biodiff-wfa2-sys/build.rs` requires the `WFA2-lib` git submodule, which GitHub tag archives exclude. Upstream deliberately publishes buildable artifacts to crates.io (the published `biodiff` crate ships a `Cargo.lock` and the published `biodiff-wfa2-sys` crate bundles the WFA2-lib C sources), but the manager's DepsAndAssets Cargo lane is hard-wired to git-tag provenance: it clones the tag, packs registry crates from the clone's lock, and rewrites `SRC_URI` to a GitHub archive. A seed ebuild shaped for the published crate would be clobbered by apply. The lane needs a second provenance, and biodiff seeded one release behind latest (1.2.0, latest 1.2.1) is the end-to-end acceptance vehicle for it.

## What Changes

- `DepsAndAssets (Cargo …)` policy gains a provenance field: `CargoGitTag` (existing behavior; hk, mise, usage) or `CargoCratesIo` (new). Version detection and tag-floor probing stay GitHub-based for both provenances.
- New CratesIo materialize lane inside the materialize container: fetch the published `{crate}-{pv}.crate` with `aria2c` (default User-Agent, matching pycargoebuild's in-container fetch posture), unpack it, run pycargoebuild against the unpacked crate, and pack registry crates from the crate's own `Cargo.lock` into the usual `{pn}-{pv}-crates.tar.xz` assets artifact.
- Ebuild `SRC_URI` rewrite gains a CratesIo branch: primary source is the canonical `https://crates.io/api/v1/crates/<crate>/<pv>/download -> <p>.crate` plus the assets crates line; GitTag rewrite behavior is unchanged byte-for-byte.
- Provenance coherence is enforced at apply: policy provenance, the ebuild source line form, and the pack lock source must agree; mismatch hard-fails before any commit. A missing published crate for the target PV hard-fails the unit at materialize naming the URL and PV; there is no plan-time crates.io probe and no silent fallback to GitTag.
- MSRV build-floor harvest reads the unpacked published crate for CratesIo (registry harvest additionally covers the newly vendored workspace-member crates such as `hexagex` and `biodiff-wfa2-sys`).
- New hardcoded policy: `dev-util/biodiff` ← GitHub `8051enthusiast`/`biodiff` tag prefix `v`, technique `DepsAndAssets (Cargo Nothing Nothing CargoCratesIo)`.
- Overlay seed (package truth, not manager runtime): `dev-util/biodiff` at PV `1.2.0` with crates.io source distfile, `IUSE="+wfa2"` default-on (USE off maps to `--no-default-features`), `BDEPEND="wfa2? ( dev-build/cmake )"` plus `llvm-core/clang` while the 1.2.0-era `-sys` crate uses bindgen, and a manually materialized `biodiff-1.2.0-crates.tar.xz` assets release with checksum sidecars. The ebuild and assets are installed, then `outdated` reports `1.2.0 -> 1.2.1` and `update` applies the bump through the new lane.

PV and package selection stay untouched: no CLI version pins; the seed PV lives only in the overlay ebuild, and `update` continues to select the remote latest.

## Capabilities

### New Capabilities
- `dev-util-biodiff-seed`: seeded overlay package truth — package identity and version pin, crates.io source distfile, `wfa2` USE flag and BDEPEND shape, vendor crates assets release materialization, Manifest/md5-cache/bootstrap, and operator smoke acceptance.

### Modified Capabilities
- `cargo-crates-assets`: the apply-source GitHub requirement is scoped to `CargoGitTag` provenance; new requirements cover the `cargoSource` policy field, CratesIo materialize steps, crates.io distfile and SRC_URI form, pack provenance from the published crate's lock, provenance coherence hard-fails, and MSRV harvest provenance.

## Impact

- Manager: `src/Update/Types.hs` (`EcosystemSpec::Cargo`, ecosystem helpers), `src/Update/Hardcoded.hs` (biodiff policy; three existing policy lines gain the provenance field), `src/Update/EbuildEdit.hs` (SRC_URI branch + coherence), `src/Update/Cargo/Crates.hs` (lane ops), `src/Update/Apply/Materialize.hs` (provenance-keyed lane selection), `src/Update/Cargo/Msrv.hs` (harvest provenance), and their test suites. No CLI, config-file, or host-toolchain changes; the materialize image recipe already includes `net-misc/aria2`.
- Overlay repo: `dev-util/biodiff` ebuild, `metadata.xml`, `Manifest`, md5-cache, signed commits.
- Assets repo: release tag `biodiff-1.2.0` (manual seed materialize) and `biodiff-1.2.1` (manager full-path apply) with `biodiff-<pv>-crates.tar.xz` and sidecars.

## Non-goals

- No git-submodule-aware source-tarball lane and no `build.rs` patching; the GitHub tag tree is not a supported source for biodiff.
- No system-WFA2 path (packaging `sci-libs/wfa2` or a dynamic-link USE variant).
- No plan-time crates.io existence probe; the materialize-time hard-fail is the failure surface.
- No general crate-name ≠ overlay-PN modeling; divergence is a hard-fail, not a parameter.
- No CHANGELOG or cabal version ritual (none exists in the repo; starting one is a separate decision).
- GitTag lane behavior and all other packages are unchanged; no other package adopts CratesIo in this change.