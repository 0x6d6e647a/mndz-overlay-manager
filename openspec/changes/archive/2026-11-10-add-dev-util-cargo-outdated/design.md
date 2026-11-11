# Design

## Context

See proposal.md for why this package is being added. `CargoCratesIo` materialize, provenance checks, and donor-ebuild rewrite already exist and are used by `dev-util/biodiff` and `dev-util/cargo-update`. `update` selects only the newest comparable GitHub tag, so the `0.18.0` seed cannot be produced by `update dev-util/cargo-outdated`.

Upstream facts:

- The crates for `0.18.0` and `0.19.0` each carry `Cargo.lock`. The `0.18.0` crate is the `v0.18.0` tag plus one CI-only commit. The `0.19.0` crate is the `v0.19.0` commit.
- `rust-version` is `1.84.0` in `0.18.0` and `1.88.0` in `0.19.0`. Edition moves from 2021 to 2024.
- The tags (and the `0.18.0` crate) carry `rust-toolchain.toml` with `channel = "nightly"`. The MSRV probe reads that file only when no `rust-version` is set, and a non-dotted channel is no floor, so the probe ignores it. Portage calls the slotted toolchain, not a rustup proxy.
- The crate ships one binary, `cargo-outdated`, and about sixteen clap-parsing unit tests in `src/cli.rs`. No `tests/`, man pages, or completions.
- Upstream Cargo features are `vendored-openssl` and `debug`. Native libraries come through the `cargo` library crate (0.87.0 and 0.91.0): `libgit2-sys`, `curl-sys`, `libssh2-sys`, `libz-sys`, `libsqlite3-sys` (rusqlite `bundled`), `openssl-sys`, and `libnghttp2-sys`. `cargo-credential-libsecret` dlopens `libsecret` at runtime.
- `libgit2-sys` accepts system libgit2 `1.9.0..1.10.0` in `0.18.0` and `1.9.2..1.10.0` in `0.19.0`. The host has `1.9.7`. Gentoo's oldest is `1.9.2`.
- The `0.18.0` lock contains `dbus`/`libdbus-sys` through `opener`, but that edge is inactive for `x86_64-unknown-linux-gnu`. No `cmake` crate appears in either lock.

## Goals / Non-Goals

**Goals:**

- One `CargoCratesIo` policy row, a policy lookup test, and a donor-preservation test so the `0.19.0` rewrite keeps the USE contract.
- A seed ebuild whose default build links every native library from the system, and whose disabled `system-*` flags select the bundled copy without ever loading two copies of OpenSSL or zlib.
- Pack `0.18.0` from the published crate inside the materialize image, then let `update` pack `0.19.0`.

**Non-Goals:**

- A new materialize code path, lock generation, or a change to the MSRV harvest or the `cfg` classifier.
- Patching upstream `Cargo.toml` to expose more features.

## Decisions

### Provenance is the published crate

Policy is `DepsAndAssets (Cargo Nothing Nothing CargoCratesIo)`, GitHub `kbknapp`/`cargo-outdated`, tag prefix `v`, empty runtime-lane allowlist. The seed pack downloads `cargo-outdated-0.18.0.crate`, runs `pycargoebuild --use-crate-tarball` on the unpacked crate, and packs `cargo-outdated-0.18.0-crates.tar.xz` with prefix `cargo_home/gentoo/`.

Alternative: `CargoGitTag`. Both tags carry a lock, so it would work, but it diverges from `cargo-update` and `biodiff` for no gain. The crate is what crates.io users install.

### One flag per bundled library

Each flag maps to the switch the build scripts honor. The table below was confirmed with `cargo tree -e features` and two spike builds of `0.19.0` (default and fully bundled) with rust-bin 1.98.1.

| Flag | Enabled | Disabled |
|---|---|---|
| `system-openssl` | `OPENSSL_NO_VENDOR=1` | Cargo feature `vendored-openssl` |
| `system-libcurl` | nothing (curl-sys probes pkg-config) | Cargo feature `cargo/all-static` |
| `system-libgit2` | `LIBGIT2_NO_VENDOR=1` | Cargo feature `cargo/vendored-libgit2` |
| `system-libssh2` | `LIBSSH2_SYS_USE_PKG_CONFIG=1` | variable left unset |
| `system-zlib` | nothing (libz-sys probes pkg-config) | `LIBZ_SYS_STATIC=1` |
| `system-sqlite` | `LIBSQLITE3_SYS_USE_PKG_CONFIG=1` | nothing (rusqlite `bundled`) |

`cargo/all-static` is the only route to a bundled curl: `curl-sys/static-curl` is not reachable from the root package, and curl-sys has no environment override. `all-static` also forces bundled OpenSSL and libgit2, which the fence below already requires. Passing `vendored-openssl` and `cargo/vendored-libgit2` alongside it is redundant and harmless, and it keeps each flag's effect explicit in `src_configure`.

`LIBGIT2_NO_VENDOR` wins over the Cargo feature and aborts when the probe fails, so it is exported only when `system-libgit2` is set.

Alternative: fold curl into `system-openssl`, because the fence forces the two to match. Rejected so each flag names the library it controls. `REQUIRED_USE` shows the coupling.

### REQUIRED_USE fence

```
REQUIRED_USE="
	!system-openssl? ( !system-libcurl !system-libgit2 !system-libssh2 )
	!system-libcurl? ( !system-openssl )
	system-libgit2? ( system-libssh2 )
	!system-zlib? ( !system-libcurl )
"
```

- Bundled OpenSSL is linked statically. A system libcurl, libgit2, or libssh2 would load the system `libssl` as well, so all three must be bundled.
- Bundled curl comes only from `all-static`, which bundles OpenSSL.
- A system `libgit2.so` brings its own libssh2, so a bundled libssh2 would never be linked.
- A bundled zlib saves nothing while a system curl, libgit2, or libssh2 loads `libz.so`. Through the chain above, `!system-zlib` forces the other five consumers bundled.

That leaves five library sets (each with `system-sqlite` on or off): all system; `-system-libgit2`; `-system-libgit2 -system-libssh2`; everything but zlib bundled; everything bundled.

### Dependencies

- `system-openssl? ( dev-libs/openssl:= )`
- `system-libcurl? ( net-misc/curl[http2,ssl] )`
- `system-libgit2? ( >=dev-libs/libgit2-1.9.2 <dev-libs/libgit2-1.10:= )`
- `system-libssh2? ( net-libs/libssh2:= )`
- `system-zlib? ( sys-libs/zlib:= )`
- `system-sqlite? ( dev-db/sqlite:3 )`
- `RDEPEND` adds `libsecret? ( app-crypt/libsecret )`
- `BDEPEND`: `virtual/pkgconfig`, `!system-openssl? ( dev-lang/perl )`

The libgit2 floor is `1.9.2` on the seed so the preserved body already satisfies `0.19.0`. `dev-build/cmake` is not needed. `libnghttp2-sys` builds with `cc` and is linked only into a bundled curl.

### Install, tests, and smoke

`cargo_src_install` installs the one binary. `QA_FLAGS_IGNORED="usr/bin/cargo-outdated"`. `RESTRICT="!test? ( test )"`, and `src_test` calls `cargo_src_test`. The tests are offline unit tests.

The smoke checks that `cargo outdated --version` contains the PV (upstream prints `cargo-outdated-outdated <PV>`) and that `--help` exits 0. Then, in a throwaway crate with `libc = "0.1"` and a temporary `CARGO_HOME`, it checks that `cargo outdated` exits 0 and lists `libc`. That run reads the crates.io index and changes nothing on the host. It exercises curl, TLS, and the registry code, which is what the bundled build most needs proved.

### What the manager may rewrite

`pycargoebuild` and the later Cargo rewrite may change `CRATES`, the generated license block, `KEYWORDS`, `RUST_MIN_VER`, and the assets `SRC_URI`. They do not touch `IUSE` or `REQUIRED_USE`. The donor-preservation test pins the full body, including the multi-line `REQUIRED_USE`.

`RUST_MIN_VER` comes from the pack harvest: the highest of the crate's `rust-version`, the source harvest, and every vendored crate's `rust-version`. It can land above `1.84.0`. The host's rust-bin 1.98.1 clears it.

## Risks / Trade-offs

- [Bundled builds compile OpenSSL, curl, libgit2, libssh2, zlib, and sqlite from the crates tarball, and upstream sets `lto = true`] → One fully bundled emerge on `0.19.0`. The spike took about five minutes on eight cores outside Portage.
- [The bundled libssh2 build script runs `git submodule update`, ignoring failure] → Harmless in the Portage work directory, which is not inside a git checkout. The spike logged `fatal: not a git repository` and built the bundled copy.
- [`libz-sys` reads `LIBZ_SYS_STATIC` when its build script is compiled] → Portage builds from a clean target directory, so the exported value applies. The spike binary had no `libz.so`.
- [A later `libgit2-sys` may move to libgit2 1.10] → The preserved range then rejects the system library and `LIBGIT2_NO_VENDOR` aborts the build. Fix with a new revision. `-system-libgit2 -system-libssh2` works in the meantime.
- [The `0.18.0` seed was not compiled in the spike] → Its build-script switches were checked in source (cargo 0.87 has `all-static`; libz-sys 1.1.20 and libssh2-sys 0.3.0 read the same variables). The seed emerge is its first compile, and a failure before merge is fixed in place.
- [The smoke needs network access to the crates.io index] → It runs outside Portage, after the emerge.
- [Publishing the assets release pushes `mndz-overlay-assets`] → That publish is part of the seed and of `update`. Leave the overlay and manager commits unpushed until the operator asks. The overlay `master` already carries unpushed commits, and the seed stacks on them.

## Migration Plan

1. Land the policy row and tests in the manager and pass `just check`.
2. Add the donor ebuild, pack and publish `cargo-outdated-0.18.0` from the materialize image, manifest, `egencache`, and a signed overlay commit. Do not push the overlay.
3. The operator emerges and smokes `0.18.0`, then runs `outdated` and `update` on a controlling TTY.
4. The operator runs the `0.19.0` default, test, fully bundled, and default-again emerges, each followed by the smoke.
5. Sync the delta specs and archive this change.

Rollback before the operator emerge is to drop the unpublished overlay commit. After a merged `0.18.0`, a broken body is a new revision, not an edit of the merged ebuild.
