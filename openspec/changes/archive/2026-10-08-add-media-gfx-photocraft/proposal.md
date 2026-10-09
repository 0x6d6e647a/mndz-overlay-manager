# Proposal

## Why

PhotoCraft (`storytold/photocraft`) has no mndz-overlay package and no manager policy, so `outdated` and `update` cannot follow its releases. The current numeric release is `0.2.0`. Seeding the predecessor `0.1.1` makes the first automated update observable: `update` always selects the newest comparable tag and will not materialize an older seed once a newer tag exists.

## What Changes

- Add overlay package `media-gfx/photocraft`, seeded at `0.1.1`, with offline crates assets, both the GUI and CLI binaries, desktop integration, and the USE/KEYWORDS contract below. Publish the `0.1.1` crates release with the existing materialize-container steps before the policy exists.
- Add `media-gfx/photocraft` to the canonical policy map: GitHub `storytold` / `photocraft`, tag prefix `v`, `DepsAndAssets` Cargo, provenance `CargoGitTag`, lock at the repository root, package subdirectory `apps/photocraft`.
- Restrict runtime lanes to `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`. When each of those arches has a lane target, planned KEYWORDS are `-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390`. The seed ebuild carries that same string so the first update does not revision-bump for keywords alone.
- After the policy is present, `outdated` reports a newer comparable numeric tag and `update` applies it through the existing Cargo full path (crate tarball, `RUST_MIN_VER`, KEYWORDS, Manifest, signed overlay commit).
- Preserve donor `IUSE`, `REQUIRED_USE`, test gating, install layout, and the extra `LICENSE` line across that rewrite.

## Capabilities

### New Capabilities

- `media-gfx-photocraft-seed`: identity of the `0.1.1` donor, USE and runtime dependencies, install layout, licenses, crates-asset prerequisites, test gating, and headless `--version` smoke.

### Modified Capabilities

- `update-source`: GitHub source for `media-gfx/photocraft`.
- `update-apply`: canonical policy entry, Cargo package subdirectory, and the runtime-lane allowlist.
- `cargo-crates-assets`: hardcoded Cargo policy for this package (`CargoGitTag`, root lock, `apps/photocraft`).
- `overlay-test-use`: `IUSE=test` and `RESTRICT="!test? ( test )"` for the photocraft workspace test phase.

## Impact

- Manager: one policy entry and package-focused tests. Cargo materialize, reuse, KEYWORDS assembly, and signed commits stay on the existing path. No new CLI flag or config key.
- Overlay: `media-gfx/photocraft/photocraft-0.1.1.ebuild`, `metadata.xml`, and `licenses/SCOWL`. `media-gfx` is already a Gentoo category.
- Assets: release tag `photocraft-0.1.1` containing `photocraft-0.1.1-crates.tar.xz` with checksum sidecars. The following `update` publishes the newer PV the same way.
- Operator smoke after emerge is `photocraft --version` and `photocraft-cli --version`. Emerge needs the operator's sudo password. The package is not a materialize-image dependency and not an overlay wait-edge provider.

## Non-goals

- A CLI version pin, a new ecosystem, or a planner that can be asked to materialize `0.1.1` after `0.2.0` exists.
- An `avif` USE flag, `ppc` or `mips` keywords, or a patch replacing `AtomicU64` on targets without 64-bit atomics.
- Installing `docs/brand`, packaging the wasm app or fuzz crates, or emerging PhotoCraft inside the materialize image.
- A native GPU smoke test, a `cross` / rustup matrix in CI, or replacing the existing README package-target examples.
