# Tasks

## 1. Policy and donor body

- [x] 1.1 Add `dev-util/cargo-outdated` to `hardcodedPolicies` in `src/Update/Hardcoded.hs`: GitHub `kbknapp`/`cargo-outdated`, tag prefix `v`, `DepsAndAssets (Cargo Nothing Nothing CargoCratesIo)`, empty runtime-lane allowlist. Verify a new `test/Test/Policy.hs` assertion that `lookupPolicy` returns that source, provenance `CargoCratesIo`, both subdirectories unset, and an empty arch list.
- [x] 1.2 Preserve the `cargo-outdated` donor body across a Cargo rewrite from a `0.18.0`-shaped donor to PV `0.19.0`. After the rewrite: `IUSE` still contains `+system-openssl`, `+system-libcurl`, `+system-libgit2`, `+system-libssh2`, `+system-zlib`, `+system-sqlite`, `+libsecret`, and `test`; the multi-line `REQUIRED_USE` still holds all four fence rules; `src_configure` still selects `cargo/all-static`, `vendored-openssl`, `cargo/vendored-libgit2`, and `LIBZ_SYS_STATIC`; `QA_FLAGS_IGNORED` still names `usr/bin/cargo-outdated`; the primary source stays the crates.io download. The rewrite may change `KEYWORDS`, `RUST_MIN_VER`, `CRATES`, the generated license block, and the assets `SRC_URI`. Verify with a fixture in `test/Test/EbuildEdit.hs` beside the `cargo-update` donor test.
- [x] 1.3 Run `just check` and `openspec validate add-dev-util-cargo-outdated --type change --strict`. Verify both exit 0.

## 2. Overlay seed ebuild

- [x] 2.1 Add `dev-util/cargo-outdated/cargo-outdated-0.18.0.ebuild` in the overlay checkout, following design.md:
  - `SRC_URI`: primary `https://crates.io/api/v1/crates/cargo-outdated/${PV}/download -> cargo-outdated-${PV}.crate`, plus the assets crates tarball.
  - `inherit cargo` only. `CRATES=""`. No `GIT_CRATES`.
  - `IUSE="+system-openssl +system-libcurl +system-libgit2 +system-libssh2 +system-zlib +system-sqlite +libsecret test"`. The four-rule `REQUIRED_USE`. `RESTRICT="!test? ( test )"`.
  - Dependencies from design.md: the six conditional library atoms (libgit2 `>=1.9.2 <1.10:=`), `libsecret? ( app-crypt/libsecret )` in `RDEPEND`, and `BDEPEND` of `virtual/pkgconfig` and `!system-openssl? ( dev-lang/perl )`. No `dev-build/cmake`.
  - `src_configure`:
    - Exports `OPENSSL_NO_VENDOR=1`, `LIBGIT2_NO_VENDOR=1`, `LIBSSH2_SYS_USE_PKG_CONFIG=1`, and `LIBSQLITE3_SYS_USE_PKG_CONFIG=1` only when the matching flag is set.
    - Exports `LIBZ_SYS_STATIC=1` only when `system-zlib` is unset.
    - Passes `vendored-openssl`, `cargo/all-static`, and `cargo/vendored-libgit2` only when the matching `system-*` flag is unset.
  - `src_test` calls `cargo_src_test`. `QA_FLAGS_IGNORED="usr/bin/cargo-outdated"`.
  - `KEYWORDS="~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86"`. `HOMEPAGE="https://github.com/kbknapp/cargo-outdated"`. `LICENSE` includes `MIT`.
  - One direct `RUST_MIN_VER`, filled in task 3.2 from the harvest, at least `1.84.0`.

  Verify the ebuild text contains those flags, `REQUIRED_USE`, the program path, and the crates.io URL, and does not inherit `mndz-cargo` or name `nghttp2`, `dbus`, `man`, or `debug` in `IUSE`.
- [x] 2.2 Add `dev-util/cargo-outdated/metadata.xml` with GitHub remote-id `kbknapp/cargo-outdated`, crates.io remote-id `cargo-outdated`, bugs-to `https://github.com/kbknapp/cargo-outdated/issues`, and a `<flag>` description for each `system-*` flag and `libsecret`. The `system-openssl` and `system-libcurl` descriptions name their `REQUIRED_USE` coupling. Verify `pkgcheck scan dev-util/cargo-outdated` (or `xmllint --noout`) reports no metadata or REQUIRED_USE errors.

## 3. Seed assets

- [x] 3.1 In the materialize image, download the published `cargo-outdated` 0.18.0 crate, unpack it, run `pycargoebuild --use-crate-tarball` on the unpacked crate, and pack `cargo-outdated-0.18.0-crates.tar.xz` with the `cargo_home/gentoo/` prefix and the hermetic tar/xz rules. Do not clone the Git tag and do not run `cargo generate-lockfile`. Verify the unpacked crate contains `Cargo.lock` and that the tarball members start with `cargo_home/gentoo/`.
- [x] 3.2 Write the pycargoebuild `CRATES` (empty), dependent license block, and harvested `RUST_MIN_VER` into the 0.18.0 ebuild without removing `IUSE`, `REQUIRED_USE`, `src_configure`, or `src_test`.
  - Publish assets release `cargo-outdated-0.18.0` with the crates tarball and `b3`, `sha256`, and `sha512` sidecars under `dev-util/cargo-outdated/`, GPG-signed. That publish updates `mndz-overlay-assets`.
  - Run `ebuild … manifest` against the manager private distdir, then package `egencache`.
  - Verify `Manifest` lists `cargo-outdated-0.18.0.crate` and `cargo-outdated-0.18.0-crates.tar.xz`, that `metadata/md5-cache/dev-util/cargo-outdated-0.18.0` exists, and that the ebuild still has the task 2.1 USE contract.
  - Commit the overlay seed signed. Do not push the overlay or the manager repo unless the operator asks.

## 4. Seed emerge

- [x] 4.1 Ask the operator to emerge `=dev-util/cargo-outdated-0.18.0` with the default USE set and without `test`, then run the functional smoke:
  - `cargo outdated --version` contains `0.18.0`, and `cargo outdated --help` exits 0.
  - In a throwaway crate depending on `libc = "0.1"` with a temporary `CARGO_HOME`, `cargo outdated` exits 0 and lists `libc`.

  Verify the emerge succeeds, the smoke passes, and the binary's dynamic dependencies include `libssl`, `libcurl`, `libgit2`, `libssh2`, `libz`, and `libsqlite3`.

## 5. Bump to 0.19.0

- [x] 5.1 Run `outdated` for `dev-util/cargo-outdated`. Verify it reports `0.18.0` to `0.19.0` and exits 0.
- [x] 5.2 Ask the operator to run `update` for `dev-util/cargo-outdated` on a TTY. Verify:
  - It publishes assets release `cargo-outdated-0.19.0` with the crates tarball and three sidecars.
  - It writes `cargo-outdated-0.19.0.ebuild` whose primary source is the crates.io download, keeping the task 2.1 USE contract and the four-rule `REQUIRED_USE`, and with `RUST_MIN_VER` at least `1.88.0`.
  - Manifest, md5-cache, and the overlay and assets commits are signed.

  Do not push the overlay or the manager repo unless the operator asks.
- [x] 5.3 Ask the operator to emerge `=dev-util/cargo-outdated-0.19.0` with the default USE set and without `test`. Verify the emerge succeeds and the functional smoke passes and reports `0.19.0`.
- [x] 5.4 Ask the operator to emerge `=dev-util/cargo-outdated-0.19.0` with `USE=test` and `FEATURES=test`, leaving the other flags at their defaults. Verify the emerge succeeds, including the upstream unit tests, and the functional smoke passes. If the tests fail because of packaging, fix the ebuild in a new revision (`0.19.0` has merged), then re-run this emerge.
- [x] 5.5 Ask the operator to emerge `=dev-util/cargo-outdated-0.19.0` with all six `system-*` flags disabled and `libsecret` enabled. Verify the emerge succeeds without fetching crates during the build, the functional smoke passes, and the binary's dynamic dependencies omit `libssl`, `libcrypto`, `libcurl`, `libgit2`, `libssh2`, `libz`, and `libsqlite3`.
- [x] 5.6 Ask the operator to emerge `=dev-util/cargo-outdated-0.19.0` again with the default USE set. Verify the emerge succeeds, the functional smoke passes, and the binary's dynamic dependencies include `libssl`, `libcurl`, `libgit2`, `libssh2`, `libz`, and `libsqlite3`.
- [x] 5.7 Run `openspec validate add-dev-util-cargo-outdated --type change --strict`. Verify it exits 0.

## Workflow follow-up

- Archive with `openspec archive` after task 5.6. Sync both deltas. Extend the `cargo-crates-assets` Purpose line so its package list includes `dev-util/cargo-outdated`. Do not push the overlay or the manager repo unless the operator asks.
