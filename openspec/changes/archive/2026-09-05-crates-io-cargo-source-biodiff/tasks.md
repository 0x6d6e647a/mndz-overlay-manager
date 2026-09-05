# Tasks: crates.io-sourced Cargo packages and dev-util/biodiff seed

## 1. Manager: Cargo provenance policy

- [x] 1.1 Extend `EcosystemSpec::Cargo` with `cargoSource :: CargoSource` (`CargoGitTag` | `CargoCratesIo`), update ecosystem helpers and the three existing policies (hk/mise/usage → `CargoGitTag`); verify with `cabal build all` and the existing test suite green (`hk check` unit/test steps)
- [x] 1.2 Add the `dev-util/biodiff` hardcoded policy: GitHub `8051enthusiast`/`biodiff` tag prefix `v`, technique `DepsAndAssets (Cargo Nothing Nothing CargoCratesIo)`; verify with a policy-resolution test asserting provenance and source

## 2. Manager: SRC_URI rewrite and provenance coherence

- [x] 2.1 Add the CratesIo `SRC_URI` rewrite branch in `Update.EbuildEdit`: primary source line `https://crates.io/api/v1/crates/<crate>/<pv>/download -> <p>.crate` plus the assets crates line, parameterized on PV; GitTag rewrite unchanged; verify with unit tests covering both forms, PV parameterization, and GitTag byte-identical regression
- [x] 2.2 Add the provenance coherence check (policy provenance ↔ ebuild source-line form ↔ pack provenance) that hard-fails naming expected and observed form before Manifest/assets/commit; verify with unit tests for the CratesIo-coherent admit and both mismatch directions

## 3. Manager: CratesIo materialize lane

- [x] 3.1 Add the fetch-and-unpack cargo op: in-container `aria2c` (default User-Agent) fetch of the published `.crate` from the crates.io download endpoint, unpack to unit `work/src` as `<p>/`; hard-fail on fetch failure (naming endpoint + PV), crate-name divergence from PN, or missing `Cargo.lock`; verify with unit tests over the injectable `CargoOps` surface
- [x] 3.2 Key full-path lane selection on provenance in `Update.Apply.Materialize`: CratesIo units run fetch+unpack→pycargoebuild→pack; GitTag units keep the clone flow byte-for-byte; verify with unit tests asserting the op sequence per provenance
- [x] 3.3 Point the manager-owned crates pack at the provenance-appropriate lock (CratesIo: unpacked crate's `Cargo.lock`); verify with a fixture-lock unit test showing `hexagex-0.2.3` and `biodiff-wfa2-sys-2.3.4-cf3eb92` style entries packed as registry crates
- [x] 3.4 Make MSRV build-floor source harvest walk the unpacked published crate for CratesIo (tag floor still tag-probed; registry harvest covers packed vendor crates); verify with unit tests for the CratesIo harvest path and unchanged GitTag harvest

## 4. Specs and docs

- [x] 4.1 Merge the change deltas into `openspec/specs/` (`cargo-crates-assets` modifications + new `dev-util-biodiff-seed`), scrubbing any delta residue ("in this change", "as today") from living SoT; verify with `openspec validate --strict`
- [x] 4.2 Confirm README/CONTRIBUTING/AGENTS need no updates (no operator CLI/config, pipeline, or agent-process change per project-docs) and record the confirmation in this change's archive notes
  - Confirmed 2026-09-05: the change adds no operator CLI surface, config keys, host toolchain, quality-pipeline step, or agent-process rule; README's DepsAndAssets prose already describes the materialize container posture generically (image provides pycargoebuild + fetchers). The overlay seed (`dev-util/biodiff`) is overlay inventory, not manager operator surface; nothing in README/CONTRIBUTING/AGENTS catalogs overlay packages, so no update is required. This note is the archive record.

## 5. Overlay seed: dev-util/biodiff 1.2.0

- [x] 5.1 Write `dev-util/biodiff/biodiff-1.2.0.ebuild` (crates.io primary `SRC_URI`, `IUSE="+wfa2"` default-on with `--no-default-features` mapping via `usex`, `BDEPEND="wfa2? ( dev-build/cmake llvm-core/clang )"`, empty `CRATES`, one `RUST_MIN_VER`, `QA_FLAGS_IGNORED="usr/bin/biodiff"`, test IUSE + `RESTRICT`) and `metadata.xml` (remote-id `8051Enthusiast/biodiff`); verify the ebuild parses with Portage (`ebuild biodiff-1.2.0.ebuild …`)
- [x] 5.2 Manually materialize the seed in the materialize image container: aria2c fetch of `biodiff-1.2.0.crate`, unpack, pycargoebuild crate-tarball mode (`-c -i -M -f --no-write-crate-tarball --crate-tarball-path biodiff-1.2.0-crates.tar.xz --crate-tarball-prefix cargo_home/gentoo`), pack per hermetic tar/xz rules; verify the tarball has `cargo_home/gentoo/` prefix including `hexagex-0.2.3/` and `biodiff-wfa2-sys-2.3.4-cf3eb92/` (with `WFA2-lib/CMakeLists.txt`)
- [x] 5.3 Publish assets release tag `biodiff-1.2.0` with the crates tarball plus `b3`/`sha256`/`sha512` sidecars committed under `dev-util/biodiff/` and a GPG-signed assets commit; verify sidecar files exist in the assets worktree
- [x] 5.4 Run `ebuild … manifest` against the manager private distdir (both distfiles fetched), `gencache dev-util/biodiff`, and GPG-signed overlay commits; verify `dev-util/biodiff/Manifest` contains both distfile entries and `metadata/md5-cache/dev-util/biodiff-1.2.0` exists

## 6. Smoke acceptance (seed → bump)

- [x] 6.1 `emerge =dev-util/biodiff-1.2.0` with default USE succeeds; `biodiff --version` reports `1.2.0` and `biodiff --help` exits 0 (seed acceptance gate)
- [x] 6.2 `cabal run mndz-overlay-manager -- outdated biodiff` prints the `1.2.0 -> 1.2.1` outdated line
- [x] 6.3 `cabal run mndz-overlay-manager -- update biodiff` applies the bump through the CratesIo lane: publishes assets release `biodiff-1.2.1`, rewrites the ebuild to 1.2.1 in the crates.io + crates-tarball SRC_URI form, regenerates Manifest + md5-cache, and creates GPG-signed overlay and assets commits; verify all four artifacts
- [x] 6.4 Emerge the bumped `=dev-util/biodiff-1.2.1`; `biodiff --version` reports `1.2.1`
- [x] 6.5 Emerge once with `USE=-wfa2` and confirm the pure-Rust build succeeds without cmake/clang involvement

## 7. Final gates

- [x] 7.1 `hk check` green over the full change (library, executable, test-suite build, tests, static analysis)
- [x] 7.2 Living-SoT scrub pass: no residual change-delta language in merged specs; technique vocabulary is DepsAndAssets throughout; verify by re-reading merged `openspec/specs/cargo-crates-assets/spec.md` and `openspec/specs/dev-util-biodiff-seed/spec.md`