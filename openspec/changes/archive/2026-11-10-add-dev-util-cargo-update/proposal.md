# Proposal

## Why

`cargo-update` is the Cargo subcommand that reports and applies updates for executables installed with `cargo install`. The mndz overlay has no `dev-util/cargo-update` ebuild, and the manager has no policy for it, so `outdated` and `update` cannot carry the package. Upstream 22.1.1 is published on crates.io and tagged on GitHub.

## What Changes

- Seed `dev-util/cargo-update` at Portage version `22.1.0` from the published crates.io crate, one release behind `22.1.1`.
- Register the package as `DepsAndAssets` Cargo with provenance `CargoCratesIo`, GitHub owner `nabijaczleweli`, repository `cargo-update`, and tag prefix `v`.
- Offer USE flags `+system-openssl`, `+system-libgit2`, `+system-libcurl`, `+libsecret`, `+man`, and `test`, with `REQUIRED_USE="system-libcurl? ( system-openssl )"`.
- Prove the seed with emerge and smoke, then `outdated`, then `update` to `22.1.1`, then emerge and smoke again, including `USE=test` with `FEATURES=test` on the default USE set.
- Prove the vendored path once on `22.1.1` with all three `system-*` flags off, then restore the default system-library install.

## Non-goals

- Generating `Cargo.lock` from the Git tag. The tag omits the lock; the published crate carries the lock upstream shipped.
- USE flags for `libssh2`, zlib, or nghttp2. Those are not upstream features of this crate.
- Shell completions. Upstream does not ship them.
- Running `cargo install-update -a` as a smoke test. That command updates the operator's real Cargo install list.
- Changing the existing `CargoCratesIo` materialize machinery. This package uses that lane as `dev-util/biodiff` does.

## Capabilities

### New Capabilities

- `dev-util-cargo-update-seed`: Overlay seed truth for `dev-util/cargo-update` at `22.1.0`: crates.io source, system-library USE flags, man pages, libsecret, gated tests, assets publish, and operator acceptance through the `22.1.1` bump and the vendored proof emerge.

### Modified Capabilities

- `cargo-crates-assets`: Add the hardcoded `dev-util/cargo-update` policy row, and require that a Cargo rewrite keep the seed ebuild body (USE flags, `REQUIRED_USE`, system-library configure, man install, and test gate).

## Impact

- Manager policy and its lookup test (`src/Update/Hardcoded.hs`, `test/Test/Policy.hs`).
- New overlay files under `dev-util/cargo-update/` (ebuild, `metadata.xml`, `Manifest`, md5-cache).
- Signed assets releases `cargo-update-22.1.0` (seed pack) and `cargo-update-22.1.1` (`update`).
- Operator emerges on the host: default `22.1.0`, default `22.1.1`, `FEATURES=test` on `22.1.1`, the all-vendored `22.1.1` proof, and a final default reinstall.
