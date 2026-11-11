# Proposal

## Why

`cargo-outdated` is the Cargo subcommand that reports out-of-date dependencies of a Rust project. The mndz overlay has no `dev-util/cargo-outdated` ebuild, and the manager has no policy for it, so `outdated` and `update` cannot carry the package. Upstream 0.19.0 is published on crates.io and tagged on GitHub, so the 0.18.0 seed can be proved through a real bump.

## What Changes

- Seed `dev-util/cargo-outdated` at Portage version `0.18.0` from the published crates.io crate, one release behind `0.19.0`.
- Register the package as `DepsAndAssets` Cargo with provenance `CargoCratesIo`, GitHub owner `kbknapp`, repository `cargo-outdated`, and tag prefix `v`.
- Offer one default-on `system-*` USE flag for each native library that can be vendored: `+system-openssl`, `+system-libcurl`, `+system-libgit2`, `+system-libssh2`, `+system-zlib`, `+system-sqlite`. Add `+libsecret` and `test`. A `REQUIRED_USE` fence rejects every combination that would load two OpenSSL or zlib copies, or that would vendor a library that nothing links.
- Prove the seed with emerge and a functional smoke, then `outdated`, then `update` to `0.19.0`, then emerge and smoke again, including `USE=test` with `FEATURES=test` on the default USE set.
- Prove the fully vendored build once on `0.19.0` with all six `system-*` flags off, then restore the default system-library install.

## Non-goals

- Generating `Cargo.lock`. The published crate and the tag both carry the lock upstream shipped.
- A USE flag for nghttp2, dbus, or upstream's `debug` feature. nghttp2 has no system probe and is only linked by vendored curl. dbus is never built on Linux GNU. `debug` only turns on developer trace printing.
- Man pages or shell completions. Upstream ships neither.
- Proving every valid USE combination. Only the default, `test`, and fully vendored sets are emerged.
- Changing the existing `CargoCratesIo` materialize machinery or the MSRV harvest. This package uses that lane as `dev-util/cargo-update` does.
- Changing `update` so it can target a non-newest PV.

## Capabilities

### New Capabilities

- `dev-util-cargo-outdated-seed`: Overlay seed truth for `dev-util/cargo-outdated` at `0.18.0`: crates.io source, the six `system-*` USE flags and their `REQUIRED_USE` fence, libsecret, gated tests, assets publish, and operator acceptance through the `0.19.0` bump and the fully vendored proof emerge.

### Modified Capabilities

- `cargo-crates-assets`: Add the hardcoded `dev-util/cargo-outdated` policy row, and require that a Cargo rewrite keep the seed ebuild body (USE flags, `REQUIRED_USE`, system-versus-vendored configure, and test gate).

## Impact

- Manager policy and its lookup test (`src/Update/Hardcoded.hs`, `test/Test/Policy.hs`), and a donor-preservation test (`test/Test/EbuildEdit.hs`).
- New overlay files under `dev-util/cargo-outdated/` (ebuild, `metadata.xml`, `Manifest`, md5-cache).
- Signed assets releases `cargo-outdated-0.18.0` (seed pack) and `cargo-outdated-0.19.0` (`update`).
- Operator emerges on the host: default `0.18.0`, default `0.19.0`, `FEATURES=test` on `0.19.0`, the fully vendored `0.19.0` proof, and a final default reinstall.
