# Proposal: add OpenAI Codex as `dev-util/codex`

## Why

The overlay wants OpenAI Codex (`openai/codex`) as a from-source `dev-util/codex` package that the manager can bump. Codex is not an hk-shaped Cargo package: the tag is `rust-v${PV}`, the workspace is virtual under `codex-rs/`, `GIT_CRATES` and extra V8 distfiles must survive `SRC_URI` rewrite, and the `v8` crate cannot be built from the crates.io tarball under Portage `network-sandbox`. GURU already ships the same atom with prebuilt musl `librusty_v8` and `~arm64`; this overlay’s product is always-from-source V8 on `-* ~amd64` only. Seed one version behind latest (0.153.3; latest stable `rust-v0.153.4`) so `outdated`/`update` is the acceptance test.

## What Changes

- New hardcoded policy: `dev-util/codex` ← GitHub `openai`/`codex` tag prefix `rust-v`, technique `DepsAndAssets (Cargo (Just "codex-rs") (Just "codex-rs/cli") CargoGitTag)`, with an amd64-only runtime-lane arch allowlist so planned KEYWORDS stay `-* ~amd64` and harvest-versus-ceiling binds only to amd64 rust.
- Cargo GitTag `SRC_URI` rewrite treats `${CARGO_CRATE_URIS}` as list-era **only when `CRATES` is non-empty**, so empty-`CRATES` + `GIT_CRATES` + extra V8/clang/rust-toolchain lines are not replaced by the two-line github+crates form.
- Full-path Cargo materialize harvests a second assets sidecar when the lock pins crates.io `v8`: clone `denoland/rusty_v8` tag `v${crate-ver}` with recursive submodules, pack `rusty-v8-${crate-ver}-with-submodules.tar.xz`, publish under assets keyed by **v8 crate version** (not Codex PV). Reuse that asset when the pin does not move. Chromium clang and rust-toolchain stay ordinary Portage GCS distfiles on the ebuild.
- Cargo MSRV tag floor `T(pv)` reads `rust-toolchain.toml` `channel` when it is a dotted version and no active-set `rust-version` exists, so Codex’s `1.95.0` gates lanes and survives into the written `RUST_MIN_VER`.
- Overlay seed (package truth): `dev-util/codex` at PV `0.153.3`, always `V8_FROM_SOURCE=1`, both `codex` and `codex-code-mode-host`, `IUSE=test` with documented cargo skips, bash/zsh/fish completions, `RDEPEND` `sys-apps/bubblewrap` + system OpenSSL, template-owned `src_prepare` that points gRPC codegen at system `protoc`, `GIT_CRATES` without `microsoft/mxc`, human-owned `S=` / V8 env / `CHECKREQS` / `RUST_MIN_STACK`. Manual seed materialize of sidecar A (`codex-0.153.3-crates.tar.xz`) and sidecar B (`rusty-v8-150.4.0-with-submodules.tar.xz`). Then `outdated` reports `0.153.3 -> 0.153.4` and `update` applies the bump (new A; B reused).

PV and package selection stay untouched: no CLI version pins; the seed PV lives only in the overlay ebuild; `update` continues to select runtime-lane targets (here the remote latest under the amd64 rust ceiling).

## Capabilities

### New Capabilities

- `dev-util-codex-seed`: seeded overlay package truth — identity and version pin, GitHub `rust-v${PV}` source, crates and rusty_v8 sidecars, always-from-source V8, amd64-only KEYWORDS, binaries and completions, sandbox/OpenSSL/protoc/gn/llvm BDEPEND/RDEPEND, `IUSE=test`, Manifest/md5-cache/bootstrap, and operator smoke acceptance.

### Modified Capabilities

- `cargo-crates-assets`: GitTag `SRC_URI` rewrite preserves `GIT_CRATES` and extra distfiles when `CRATES` is empty; full-path harvest/publish/reuse of a rusty_v8+submodules sidecar keyed by the lock’s `v8` crate version; omit Windows-only git remotes from overlay `GIT_CRATES`; `rust-toolchain.toml` dotted `channel` as `T(pv)` when no `rust-version` exists; hardcoded policy for `dev-util/codex`.
- `runtime-lanes`: DepsAndAssets policy MAY restrict which runtime arches participate in lane planning and KEYWORDS collapse (Codex: amd64 only).

## Impact

- Manager: `src/Update/Hardcoded.hs` (codex policy + arch allowlist), `src/Update/Types.hs` (policy/arch field if required), `src/Update/EbuildEdit.hs` (`hasListEraCargoDeps` / `ensureCargoAssetsSrcUri` extra-line preservation), `src/Update/Cargo/Crates.hs` and `src/Update/Apply/Materialize.hs` (sidecar B harvest/reuse), `src/Update/Cargo/Msrv.hs` (`rust-toolchain.toml` floor), `src/Update/Go/Lanes.hs` / planning (arch allowlist), and their test suites. No new operator CLI subcommand or config key. Materialize image needs `git` submodule support for sidecar B (already present for GitTag clone).
- Overlay repo: `dev-util/codex` ebuild, `metadata.xml`, `Manifest`, md5-cache, signed commits. GURU’s same atom is not masked.
- Assets repo: release `codex-0.153.3` (crates tarball) and `rusty-v8-150.4.0` (submodule snapshot) for the seed; `update` publishes `codex-0.153.4` crates and reuses rusty_v8 `150.4.0`.

## Non-goals

- No official musl `librusty_v8` prebuilt, no npm Codex, no Chromium `dev-lang/v8` or overlay `dev-libs/rusty-v8` product, no bun/JSC, no USE flag to skip from-source V8.
- No `package.mask` of GURU `dev-util/codex`.
- No native from-source V8 on arm64/ppc/riscv/loong (Chromium host clang/rust-toolchain are `Linux_x64` only).
- No `string.rs` bindgen-name FILESDIR (Codex lock’s bindgen 0.72.1 matches upstream names).
- No dropping `protoc-bin-vendored-*` from sidecar A / `Cargo.lock` (system `protoc` is execute-path purism only).
- No disabling the CLI `codex update` self-updater.
- No elvish/powershell completions (overlay `shell-completion` eclass ships bash/zsh/fish only).
- No CHANGELOG or cabal version ritual.
- Other Cargo packages keep rust-board KEYWORDS and do not grow a rusty_v8 sidecar unless their lock pins crates.io `v8` the same way.
