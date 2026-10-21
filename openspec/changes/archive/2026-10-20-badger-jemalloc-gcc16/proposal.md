# Proposal

## Why

`dev-db/badger-4.9.6` with `USE=jemalloc` dies in the private jemalloc 5.3.0 build. `src/jemalloc_cpp.cpp` calls `std::__throw_bad_alloc()`, a libstdc++ internal that GCC 16.2.1 no longer declares from `<new>`. Gentoo already fixed the same tarball in `dev-libs/jemalloc` (bug 967868, RESOLVED FIXED). This ebuild unpacks stock 5.3.0 and never applies that patch, so `ego build` never starts. `4.9.6` is on `origin/master` (`1a61bee`) and installed, built on 17 October before `/usr/bin/g++` switched to gcc-16.

## What Changes

- Publish `dev-db/badger-4.9.6-r1` and remove the unrevisioned `4.9.6` ebuild.
- Copy Gentoo's `jemalloc-5.3.0-dont-call-libstdcxx-internals.patch` into `dev-db/badger/files/`.
- `eapply` that patch inside the `USE=jemalloc` `pushd` of `${WORKDIR}/jemalloc-5.3.0`, before `econf`.
- Regenerate md5-cache as `metadata/md5-cache/dev-db/badger-4.9.6-r1` and drop `badger-4.9.6`.

## Non-goals

- No manager Haskell, no new apply rewrite fields, and no vendor-tarball republish.
- No jemalloc pin bump. Stay on 5.3.0. Upstream 5.4.0 contains the fix (PR #2900), and Gentoo's 5.4.0-r2 still carries a second patch (bug 984178). Badger's Makefile pins 5.3.1, which still has the old call.
- No `--disable-cxx`. Ristretto only needs the C API, and the shipped library keeps the C++ wrappers this ebuild already builds.
- No `sed` of `jemalloc_cpp.cpp`. The ristretto `#cgo LDFLAGS` rewrite stays a `sed` because `${jelib}` is known only at build time.
- No `dev-libs/jemalloc` dependency. That package deletes static archives and does not use the `je_` prefix.
- No `PATCHES=()` entry. `go-module` `src_prepare` applies that array to the badger tree, and `jemalloc_cpp.cpp` is not in it.
- No KEYWORDS, `SRC_URI`, `LICENSE`, `BDEPEND`, or `IUSE` change.
- No living-spec delta. `dev-db-badger-seed` already requires a fixed upstream jemalloc tarball, `--with-jemalloc-prefix=je_`, `-tags=jemalloc`, and no `dev-libs/jemalloc` dependency. `skip_specs: true`.
- No `README.md`, `CONTRIBUTING.md`, or `AGENTS.md` edit. Operator CLI, config, and the quality pipeline do not change.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- (none — `skip_specs: true`)

## Impact

- **mndz-overlay:** rename `dev-db/badger/badger-4.9.6.ebuild` to `badger-4.9.6-r1.ebuild`, add `dev-db/badger/files/jemalloc-5.3.0-dont-call-libstdcxx-internals.patch`, rename `metadata/md5-cache/dev-db/badger-4.9.6` to `badger-4.9.6-r1`. `thin-manifests` leaves `Manifest` `DIST` lines unchanged. One overlay commit, subject `dev-db/badger: 4.9.6-r1`, empty body.
- **mndz-overlay-assets:** none.
- **mndz-overlay-manager:** planning artifacts only. No Haskell. The next `update dev-db/badger` copies this ebuild body. `removeEbuild` deletes only the old ebuild, so `files/` stays.
- **Operator:** `emerge -av1 =dev-db/badger-4.9.6-r1`, then `badger --help`. `USE=jemalloc` is on globally via `USE_MISC` in `/etc/portage/make.conf`.
