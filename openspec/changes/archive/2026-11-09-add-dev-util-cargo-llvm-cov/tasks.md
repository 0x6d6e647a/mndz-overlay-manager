# Tasks

## 1. Lockless Git tag provenance

- [x] 1.1 Add `CargoGitTagGenerateLock` to `CargoSource` in `src/Update/Types.hs` and update every `CargoSource` match in the library and tests so the package builds. Verify `cabal build all` exits 0 and no match treats the new constructor as `CargoCratesIo`.
- [x] 1.2 In the full-path Cargo materialize (`src/Update/Cargo/Crates.hs` and the op wiring it uses), when provenance is `CargoGitTagGenerateLock` and `Cargo.lock` is absent at the lock root, run `cargo generate-lockfile` in the materialize container before `pycargoebuild`. Leave an existing lock unchanged. A non-zero generate exits the unit with an error that names the lock root and does not run `pycargoebuild`. Verify with unit tests on the injectable `CargoOps` surface: missing lock generates then packs, existing lock does not generate, generate failure does not pack.
- [x] 1.3 Keep provenance `CargoGitTag` failing when `Cargo.lock` is absent, without calling `cargo generate-lockfile`. Verify with a unit test that a `CargoGitTag` checkout with no lock is a hard failure and the generate op was not called.

## 2. Policy, source form, and donor body

- [x] 2.1 Add `dev-util/cargo-llvm-cov` to `hardcodedPolicies`: GitHub `taiki-e`/`cargo-llvm-cov`, tag prefix `v`, `DepsAndAssets (Cargo Nothing Nothing CargoGitTagGenerateLock)`, empty runtime-lane allowlist. Verify a new `test/Test/Policy.hs` assertion that `lookupPolicy` returns that source, provenance, both subdirectories unset, and an empty arch list.
- [x] 2.2 Treat `CargoGitTagGenerateLock` like `CargoGitTag` in provenance coherence and in the `SRC_URI` rewrite: primary line is the GitHub tag archive, plus the assets crates tarball, and `${CARGO_CRATE_URIS}` stays when `CRATES` is empty and `GIT_CRATES` is present. A crates.io primary line hard-fails before Manifest or commit. Verify `test/Test/EbuildEdit.hs` cases for the admitted GitHub form, the rejected crates.io form, and the kept `GIT_CRATES` fetch line on `cargo-llvm-cov`.
- [x] 2.3 Preserve the `cargo-llvm-cov` donor body across a Cargo rewrite: `IUSE`, `RESTRICT`, `RDEPEND`, `BDEPEND`, the `/usr/bin` wrapper install, `/usr/libexec/cargo-llvm-cov/cargo-llvm-cov`, `src_test` skips of `trybuild` and `ui_test`, and `QA_FLAGS_IGNORED`. The rewrite still updates the PV filename, `KEYWORDS`, `RUST_MIN_VER`, `CRATES`, `GIT_CRATES`, the generated crate-license block, and the assets `SRC_URI`. Verify with an ebuild-edit fixture from a 0.9.0-shaped donor to PV 0.9.1.
- [x] 2.4 Run `just check` and `openspec validate add-dev-util-cargo-llvm-cov --type change --strict`. Verify both exit 0.

## 3. Overlay seed ebuild

- [x] 3.1 Add `dev-util/cargo-llvm-cov/cargo-llvm-cov-0.9.0.ebuild` and `metadata.xml` in the overlay checkout. Primary `SRC_URI` is the `v${PV}` GitHub tag archive. `CRATES` is empty. `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`. No `nextest`, `open`, or `ffi` flag. `RDEPEND` includes unslotted `llvm-core/llvm`. `BDEPEND` includes `test? ( dev-vcs/git )`. `KEYWORDS` is `~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`. `HOMEPAGE` is `https://github.com/taiki-e/cargo-llvm-cov`. `LICENSE` contains `|| ( Apache-2.0 MIT )`. `metadata.xml` has GitHub remote-id `taiki-e/cargo-llvm-cov` and crates remote-id `cargo-llvm-cov`. One direct `RUST_MIN_VER`, filled in task 4.2 from the harvest, at least `1.87.0`. Verify `ebuild cargo-llvm-cov-0.9.0.ebuild clean` parses and the file names no crates.io URL and no release-binary tarball.
- [x] 3.2 Add `files/cargo-llvm-cov`, installed as `/usr/bin/cargo-llvm-cov`, execing `/usr/libexec/cargo-llvm-cov/cargo-llvm-cov`. It sets only an unset `LLVM_COV` or `LLVM_PROFDATA` from the LLVM major in `rustc -vV` to `/usr/lib/llvm/<major>/bin/`, and exits non-zero without exec when that path is missing. `QA_FLAGS_IGNORED` includes `usr/libexec/cargo-llvm-cov/cargo-llvm-cov`. `src_test` sources that same file, turns the unpacked tree into a git commit with inline `user.name` and `user.email` so fixture dotfiles are tracked, sets `CARGO_SKIP_TESTS=( trybuild ui_test )`, and calls `cargo_src_test`. Verify the ebuild's `src_install` references both paths and `src_test` names `CARGO_SKIP_TESTS` and `${FILESDIR}/cargo-llvm-cov`.

## 4. Seed assets

- [x] 4.1 In the materialize image, clone tag `v0.9.0`, run `cargo generate-lockfile` because the tag has no `Cargo.lock`, run `pycargoebuild --use-crate-tarball`, and pack `cargo-llvm-cov-0.9.0-crates.tar.xz` with the `cargo_home/gentoo/` prefix and the hermetic tar/xz rules. Verify the generated lock pins `test-helper` at revision `82e3b012a49fb16587e165986674290ef682a5b0` and the tarball members start with `cargo_home/gentoo/`.
- [x] 4.2 Write the pycargoebuild `CRATES` (empty), `GIT_CRATES`, dependent license block, and harvested `RUST_MIN_VER` into the 0.9.0 ebuild. `GIT_CRATES` names `test-helper` at that revision and `SRC_URI` includes `${CARGO_CRATE_URIS}`. Publish assets release `cargo-llvm-cov-0.9.0` with the crates tarball and `b3`, `sha256`, and `sha512` sidecars under `dev-util/cargo-llvm-cov/`, GPG-signed. Run `ebuild … manifest` against the manager private distdir and package `egencache`. Verify `Manifest` lists the tag archive, the crates tarball, and the `test-helper` distfile, and `metadata/md5-cache/dev-util/cargo-llvm-cov-0.9.0` exists. Commit the overlay seed signed. Do not push unless the operator asks.

## 5. Seed emerge

- [x] 5.1 Ask the operator to emerge `=dev-util/cargo-llvm-cov-0.9.0` without `test`. Verify the emerge succeeds, `cargo llvm-cov --version` reports `0.9.0`, and `cargo llvm-cov` on a `cargo new --lib` crate with no dependencies exits 0 when `LLVM_COV` and `LLVM_PROFDATA` are unset.
- [x] 5.2 Ask the operator to emerge `=dev-util/cargo-llvm-cov-0.9.0` with `FEATURES=test`. If a golden-file test fails on this LLVM, add that test name to `CARGO_SKIP_TESTS`, comment why, and add it to the skip list in `specs/dev-util-cargo-llvm-cov-seed/spec.md`. Verify the test emerge succeeds and the same two smokes still pass with both LLVM variables unset. This task finishes before `outdated`.

## 6. Bump to 0.9.1

- [x] 6.1 Run `outdated` for `dev-util/cargo-llvm-cov`. Verify it reports `0.9.0` to `0.9.1` and exits 0.
- [x] 6.2 Ask the operator to run `update` for `dev-util/cargo-llvm-cov` on a TTY. Verify it publishes assets release `cargo-llvm-cov-0.9.1` with the crates tarball and three sidecars, writes `cargo-llvm-cov-0.9.1.ebuild` whose primary source is the GitHub tag archive, and keeps the wrapper paths, `IUSE`, unslotted `llvm-core/llvm`, and the `trybuild` / `ui_test` skips. The 0.9.0 ebuild is removed. Manifest, md5-cache, and the overlay and assets commits are signed. Do not push unless the operator asks.
- [x] 6.3 Ask the operator to emerge `=dev-util/cargo-llvm-cov-0.9.1` without `test`, run both smokes expecting version `0.9.1`, then emerge that atom with `FEATURES=test` and run both smokes again. Verify each emerge and each smoke exits 0.
- [x] 6.4 Run `openspec validate add-dev-util-cargo-llvm-cov --type change --strict`. Verify it exits 0 after any skip-list edit from task 5.2.

## Workflow follow-up

- Archive with `openspec archive` after the 0.9.1 test emerge. Sync both deltas. Extend the `cargo-crates-assets` Purpose line so it names provenance `CargoGitTagGenerateLock`. Do not push unless the operator asks.
