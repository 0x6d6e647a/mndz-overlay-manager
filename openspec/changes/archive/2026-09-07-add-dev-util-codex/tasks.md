## 1. Manager: policy and amd64-only lanes

- [x] 1.1 Add a per-package runtime-lane arch allowlist (empty = all runtime arches) and set `dev-util/codex` to `amd64` only; verify with unit tests that Codex plans `-* ~amd64` and does not emit arm64 lanes or harvest-versus-ceiling against arm64, and that hk still uses every rust/rust-bin arch without `-*`
- [x] 1.2 Add hardcoded policy `dev-util/codex`: GitHub `openai`/`codex` tag prefix `rust-v`, `DepsAndAssets (Cargo (Just "codex-rs") (Just "codex-rs/cli") CargoGitTag)`; verify with a policy-resolution test asserting source, subdirs, provenance, and allowlist

## 2. Manager: SRC_URI rewrite and GIT_CRATES

- [x] 2.1 Change list-era detection so `${CARGO_CRATE_URIS}` is list-era only when `CRATES` is non-empty; verify hk/mise-style list-era still rewrites to github archive + crates tarball and a Codex-shaped empty-`CRATES` + `GIT_CRATES` + extra V8/GCS lines is not collapsed
- [x] 2.2 Preserve extra `SRC_URI` companions (rusty_v8 snapshot, Chromium GCS clang/rust-toolchain) across GitTag rewrite; verify with a unit test that those lines survive `ensureCargoAssetsSrcUri`
- [x] 2.3 Omit windows-only git remotes from written `GIT_CRATES`; verify a fixture lock with `microsoft/mxc` under `cfg(windows)` drops mxc and keeps Linux git remotes

## 3. Manager: MSRV rust-toolchain.toml

- [x] 3.1 When the active set has no `rust-version`, parse lock-root (else repo-root) `rust-toolchain.toml` dotted `channel` as `T(pv)`; ignore `stable`/`nightly`; malformed file fails the plan; verify Codex-like `channel = "1.95.0"` yields tag floor `1.95.0` (not `0.0.0`) and `channel = "stable"` does not invent a floor

## 4. Manager: rusty_v8 sidecar

- [x] 4.1 Parse crates.io `v8` pin from the provenance `Cargo.lock`; if absent, skip sidecar B; verify hk lock does not require a rusty_v8 snapshot and a Codex-like lock reports `150.4.0`
- [x] 4.2 Full-path: reuse `rusty-v8-${ver}-with-submodules.tar.xz` when the assets release exists and bytes verify; otherwise clone `denoland/rusty_v8` tag `v${ver}` with recursive submodules in the materialize container, pack hermetic tar/xz, publish keyed by crate version; verify same-pin reuse does not clone and missing pin harvests
- [x] 4.3 Do not pack the rusty_v8 tree into `{pn}-{pv}-crates.tar.xz`; verify pack still includes registry `v8-${ver}` when the lock has a checksum and still excludes git crates

## 5. Specs and docs

- [x] 5.1 Merge the change deltas into `openspec/specs/` (`cargo-crates-assets`, `runtime-lanes`, new `dev-util-codex-seed`), scrubbing delta residue from living SoT; verify with `openspec validate --strict`
- [x] 5.2 Confirm README/CONTRIBUTING/AGENTS need no updates (no operator CLI/config, pipeline, or agent-process change per `project-docs`) and record that confirmation in this change’s archive notes when archiving

## 6. Overlay seed: dev-util/codex 0.153.3

- [x] 6.1 Write `dev-util/codex/codex-0.153.3.ebuild` and `metadata.xml` per `dev-util-codex-seed` (GitHub `rust-v${PV}`, `S=…/codex-rs`, empty `CRATES`, `GIT_CRATES` without mxc, `KEYWORDS="-* ~amd64"`, both bins, completions, bwrap+openssl, gn/ninja/protobuf/python/llvm:22, `V8_FROM_SOURCE=1`, `LIBCLANG_PATH`, `CHECKREQS`, `RUST_MIN_STACK`, `IUSE=test`, `src_prepare` system-protoc rewrite, extra SRC_URI); verify Portage parses the ebuild
- [x] 6.2 Manually materialize sidecar A `codex-0.153.3-crates.tar.xz` in the materialize image (clone tag, pycargoebuild crate-tarball mode, manager-style pack); verify `cargo_home/gentoo/` prefix and no git-crate members
- [x] 6.3 Manually materialize sidecar B `rusty-v8-150.4.0-with-submodules.tar.xz` (clone `v150.4.0` --recursive, hermetic pack); verify ICU `icudtl.dat` and `icu_calendar_data-v2/build.rs` are inside
- [x] 6.4 Fetch Chromium GCS `Linux_x64` clang 23 and rust-toolchain distfiles into the manager private distdir; publish assets releases `codex-0.153.3` and `rusty-v8-150.4.0` with checksum sidecars and GPG-signed assets commits; verify sidecar files exist in the assets worktree
- [x] 6.5 Run `ebuild … manifest` against the manager private distdir, `gencache dev-util/codex`, and GPG-signed overlay commits; verify `Manifest` lists archive, crates tarball, rusty_v8 snapshot, clang, and rust-toolchain, and md5-cache exists

## 7. Smoke acceptance (seed → bump)

- [x] 7.1 `emerge =dev-util/codex-0.153.3` under `network-sandbox` succeeds; `codex --version` reports `0.153.3`; `codex-code-mode-host --help` exits 0; `codex completion bash` emits a completion function (if `dev-build/gn` is too old, pin gn or add a distfile as a seed revision and re-run this task)
- [x] 7.2 `cabal run mndz-overlay-manager -- outdated codex` prints a `0.153.3 -> 0.153.4` line labeled with `dev-lang/rust|rust-bin` amd64 (not arm64)
- [x] 7.3 `cabal run mndz-overlay-manager -- update codex` applies 0.153.4: publishes `codex-0.153.4` crates, reuses rusty_v8 `150.4.0` (no new clone), preserves `GIT_CRATES`/V8 extras/`-* ~amd64`, regenerates Manifest + md5-cache, GPG-signed overlay and assets commits; verify all of those artifacts
- [x] 7.4 Emerge `=dev-util/codex-0.153.4` under `network-sandbox`; `codex --version` reports `0.153.4`

## 8. Final gates

- [x] 8.1 `hk check` green over the full manager change (library, executable, test-suite build, tests, static analysis)
- [x] 8.2 Living-SoT scrub pass: no residual change-delta language in merged specs; technique vocabulary is DepsAndAssets throughout; verify by re-reading merged `openspec/specs/cargo-crates-assets/spec.md`, `openspec/specs/runtime-lanes/spec.md`, and `openspec/specs/dev-util-codex-seed/spec.md`
