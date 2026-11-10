# Design

## Context

See proposal.md for why this package is being added. `CargoCratesIo` materialize, provenance checks, and donor-ebuild rewrite already exist and are used by `dev-util/biodiff`. `update` selects only the newest comparable GitHub tag, so the `22.1.0` seed cannot be produced by `update dev-util/cargo-update`.

The Git tag `v22.1.1` has no `Cargo.lock` (the repository gitignore drops it). The crates.io crate for `22.1.0` and `22.1.1` contains `Cargo.lock`, `tests/`, `test-data/`, and `man/*.md`. Upstream Cargo features are `vendored-openssl` (also `curl/static-ssl`), `vendored-libgit2`, and `vendored-libcurl`. `libgit2-sys` 0.18.2 accepts system libgit2 only in `1.9.0 .. 1.10.0`, and `LIBGIT2_NO_VENDOR` forces that probe and aborts when it fails. `curl-sys` uses system libcurl unless `static-curl` is set, and still builds `libnghttp2-sys` because the curl dependency enables `http2`.

## Goals / Non-Goals

**Goals:**

- Register one `CargoCratesIo` policy row and a donor-preservation test so the `22.1.1` rewrite keeps the USE contract.
- Seed an ebuild whose default build links system OpenSSL, libgit2, and libcurl, and whose disabled `system-*` flags pass the matching vendored Cargo features.
- Pack `22.1.0` from the published crate inside the materialize image, then let `update` pack `22.1.1`.

**Non-Goals:**

- A new materialize code path, a `cargo generate-lockfile` step, or a USE flag for libssh2, zlib, or nghttp2.
- Changing `update` so it can target a non-newest PV.

## Decisions

### Provenance is the published crate

Policy is `DepsAndAssets` Cargo, provenance `CargoCratesIo`, GitHub `nabijaczleweli`/`cargo-update`, tag prefix `v`, no lock subdirectory, no package subdirectory, empty runtime-lane allowlist. The seed pack downloads `cargo-update-22.1.0.crate`, runs `pycargoebuild --use-crate-tarball` on the unpacked crate, and packs `cargo-update-22.1.0-crates.tar.xz` with prefix `cargo_home/gentoo/`.

Alternative: `CargoGitTagGenerateLock` on the tag. That produces a lock resolved at pack time, not the lock upstream published. The published crate already contains the tests and the manual, so the lockless-tag exception used by `cargo-llvm-cov` does not apply.

### USE flags select system or vendored

`IUSE="+system-openssl +system-libgit2 +system-libcurl +libsecret +man test"` and `REQUIRED_USE="system-libcurl? ( system-openssl )"`.

`src_configure` builds a feature list and exports probe variables only for the system side:

- `system-openssl` set: `OPENSSL_NO_VENDOR=1`, and do not pass `vendored-openssl`. Unset: pass `vendored-openssl`.
- `system-libgit2` set: `LIBGIT2_NO_VENDOR=1`, and do not pass `vendored-libgit2`. Unset: leave `LIBGIT2_NO_VENDOR` unset and pass `vendored-libgit2`. The variable wins over the Cargo feature, so it must not be set in the vendored build.
- `system-libcurl` set: do not pass `vendored-libcurl`. Unset: pass `vendored-libcurl`.
- Always set `LIBSSH2_SYS_USE_PKG_CONFIG=1`. `libz-sys` follows pkg-config on its own.

`cargo_src_install` installs every binary the crate builds. These versions build `cargo-install-update` and `cargo-install-update-config`. Naming them with `--bin` would drop a later upstream binary until an ebuild-body edit.

Dependencies:

- `system-openssl? ( dev-libs/openssl:= )`
- `system-libgit2? ( >=dev-libs/libgit2-1.9.0 <dev-libs/libgit2-1.10:= )`
- `system-libcurl? ( net-misc/curl[http2] )`
- `libsecret? ( app-crypt/libsecret )` in `RDEPEND`
- `net-libs/libssh2:=` and `sys-libs/zlib:=` in `DEPEND` and `RDEPEND`
- `BDEPEND`: `virtual/pkgconfig`, `dev-build/cmake`, `man? ( app-text/ronn-ng )`, `!system-openssl? ( dev-lang/perl )`

`cmake` stays unconditional because `libnghttp2-sys` compiles even when system curl is used. Perl is only required to configure vendored OpenSSL.

Alternative: three independent flags with no `REQUIRED_USE`. `vendored-openssl` turns on `curl/static-ssl`, so system libcurl plus vendored OpenSSL links two OpenSSL copies. `REQUIRED_USE` rejects that pair and still allows vendored curl with system OpenSSL.

### Man pages

When `man` is set, `src_install` renders `man/*.md` with `ronn -r` under `HOME` in `${T}` and `RUBYOPT="-Eutf-8:utf-8"`, then installs the two `.1` files. The markdown contains non-ASCII characters. When `man` is unset, skip `ronn`.

### Tests and smoke

`RESTRICT="!test? ( test )"`. `src_test` calls the cargo eclass test phase. The suite reads `test-data/` from the package root and does not need network or git.

Smoke is `cargo install-update --version` and `--help` on both binaries. `cargo install-update-config --version` is the upstream version-requirement option, not the tool version. Do not run `cargo install-update -a`.

The proof order is: default `22.1.0` emerge and smoke; `outdated`; `update`; default `22.1.1` emerge and smoke; `USE=test FEATURES=test` on `22.1.1`; emerge `22.1.1` with the three `system-*` flags off; emerge `22.1.1` again with default USE so the host is left on the system libraries.

### What the manager may rewrite

`pycargoebuild` and the later Cargo rewrite may change `CRATES`, the generated license block, `KEYWORDS`, `RUST_MIN_VER`, and the assets `SRC_URI`. They must leave `IUSE`, `REQUIRED_USE`, `RESTRICT`, the conditional dependencies, `src_configure`, `src_install`, `src_test`, and `QA_FLAGS_IGNORED` in place. Add a donor-preservation test next to the existing `cargo-llvm-cov` case, and a policy lookup test for the new key.

`KEYWORDS` on the seed is `~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`. One direct `RUST_MIN_VER`, three components, at least `1.86.0`, taken from the pack harvest when that floor is higher.

### Apple vendor cfg

`cargo-update` 22.1.0 and 22.1.1 declare `cfg(target_vendor = "apple")` and `cfg(all(unix, not(target_vendor = "apple")))` on registry dependencies. `apple` is the Apple vendor, not a modeled Gentoo family, so it holds for no family the way `win7` does. The Apple-only table is ignored. The Unix table that excludes Apple stays active on Linux. `target_vendor = "unknown"` stays unparsed, because that is the ordinary Linux vendor.

## Risks / Trade-offs

- [Vendored OpenSSL compiles a full OpenSSL from the crates tarball] → Run that USE combination once, on `22.1.1`, after the default and test emerges.
- [`libgit2-sys` aborts when `LIBGIT2_NO_VENDOR=1` and pkg-config cannot see libgit2 1.9.x] → The dependency atom is bounded to that series. Do not set the variable on the vendored build.
- [rustc 1.98.1 rejects a target directory whose path contains `:`] → If the Portage work directory's timezone offset trips that check, set `CARGO_TARGET_DIR` outside the work directory for the emerge. Do not add that export unless the seed compile hits it.
- [`libnghttp2-sys` builds even for a system-curl install] → Accept the extra compile. There is no upstream flag to skip it.
- [A `22.1.0` emerge that fails before merge] → Edit that ebuild in place. Use `-rN` only after `22.1.0` has actually merged.
- [Publishing the assets release pushes `mndz-overlay-assets`] → That publish is part of the seed and of `update`. Leave the overlay and manager commits unpushed until the operator asks.

## Migration Plan

1. Land the policy row and tests in the manager and pass `just check`.
2. Add the donor ebuild, pack and publish `cargo-update-22.1.0` from the materialize image, manifest, `egencache`, and a signed overlay commit. Do not push the overlay.
3. The operator emerges and smokes `22.1.0`, then runs `outdated` and `update` on a controlling TTY.
4. The operator runs the `22.1.1` default, test, vendored, and default-again emerges.
5. After those succeeds, sync the delta specs and archive this change.

Rollback before the operator emerge is to drop the unpublished overlay commit. After a merged `22.1.0`, a broken body is a new revision, not an edit of the merged ebuild.

## Open Questions

None. The USE polarity, `REQUIRED_USE`, default-on `libsecret` and `man`, and the single vendored proof emerge are decided.
