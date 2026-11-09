# Proposal

## Why

`cargo-llvm-cov` is the Cargo subcommand this overlay should use for LLVM source-based coverage, and it is not packaged yet. Upstream gitignores `Cargo.lock`, so the existing Git tag lane cannot pack it, and the published crate cannot run the upstream tests.

## What Changes

- Add `dev-util/cargo-llvm-cov` to the mndz overlay, seeded at 0.9.0 (one release behind 0.9.1), then prove `outdated` and `update` through 0.9.1.
- Add Cargo provenance `CargoGitTagGenerateLock`: clone the GitHub tag, run `cargo generate-lockfile` in the materialize image when `Cargo.lock` is absent, then follow the existing Git tag pycargoebuild and crates-tarball pack.
- Install a wrapper that points `LLVM_COV` and `LLVM_PROFDATA` at the `llvm-core/llvm` slot matching the running `rustc`, and run the upstream test suite under `FEATURES=test` with the two network-fetching fixture tests skipped.
- Keep `CargoGitTag` failing closed when a lock is missing. hk, mise, usage, codex, and the Storytold craft apps stay on that provenance.

## Capabilities

### New Capabilities

- `dev-util-cargo-llvm-cov-seed`: Overlay seed for `dev-util/cargo-llvm-cov` at PV 0.9.0: GitHub tag archive, generated lock and crates tarball, LLVM wrapper, gated `src_test`, and the emerge, smoke, `FEATURES=test`, `outdated`, and `update` acceptance loop through 0.9.1.

### Modified Capabilities

- `cargo-crates-assets`: Third Cargo provenance `CargoGitTagGenerateLock`, its materialize step, GitHub-archive `SRC_URI` coherence, the `dev-util/cargo-llvm-cov` policy, and survival of that package's donor body across bumps.

## Impact

- Manager: `CargoSource`, hardcoded policy, full-path Cargo materialize, provenance coherence, and `SRC_URI` rewrite. Unit tests for the new provenance and the policy lookup.
- Overlay checkout `mndz-overlay`: `dev-util/cargo-llvm-cov` ebuild, `metadata.xml`, Manifest, and md5-cache. Assets release on `mndz-overlay-assets` for 0.9.0 (hand pack) and 0.9.1 (`update`).
- No new CLI command, config key, or README package catalog. `update` still selects the newest tag and is not given a PV argument.

## Non-goals

- Packaging from the crates.io `.crate`. That tarball drops the `test-helper` git dev-dependency and omits `tests/fixtures/crates/`.
- A product USE flag for nextest, `--open`, or `--include-ffi`. `debug` stays the `cargo.eclass` flag.
- An `optfeature` hint for `cargo-nextest`.
- Pinning `llvm-core/llvm:22`. The wrapper follows `rustc -vV`.
- Vendoring the `trybuild` and `ui_test` fixture dependencies so those two tests can run offline.
- A manager command that packs the on-disk PV while a newer tag exists. The 0.9.0 assets publish stays a manual materialize-image pack, as with the biodiff seed.
- Changing missing-lock behavior for `CargoGitTag` or `CargoCratesIo`.
