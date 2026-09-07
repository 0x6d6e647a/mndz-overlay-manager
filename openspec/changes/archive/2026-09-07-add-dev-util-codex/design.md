## Context

See `proposal.md` for motivation. Today the Cargo GitTag lane clones a tag, runs pycargoebuild, packs **registry** crates (checksummed lock entries only), and `ensureCargoAssetsSrcUri` rewrites `SRC_URI` to GitHub archive + `{pn}-{pv}-crates.tar.xz` whenever the ebuild contains `CARGO_CRATE_URIS`. That is correct for hk/mise/usage (non-empty `CRATES` list-era → tarball shape). Codex is a virtual workspace at `codex-rs/`, tag prefix `rust-v`, empty `CRATES`, `GIT_CRATES`, and extra V8 distfiles. crates.io `v8-150.4.0` is not a from-source tree; `denoland/rusty_v8` tag `v150.4.0` plus 20 recursive submodules is. Chromium host clang/rust-toolchain exist only as `Linux_x64` GCS objects. Spike on this host compiled both bins offline after path-patching that git tree (`codex-cli 0.153.3`).

## Goals / Non-Goals

**Goals:**

- Extend GitTag materialize and `SRC_URI` rewrite so Codex’s empty-`CRATES` + `GIT_CRATES` + extra distfiles survive apply.
- Add a v8-crate-version-keyed rusty_v8+submodules sidecar without forking a second Cargo provenance.
- Restrict Codex runtime lanes to amd64 and read `rust-toolchain.toml` dotted `channel` as `T(pv)` when no `rust-version` exists.
- Seed 0.153.3 and accept via `outdated`/`update` to 0.153.4.

**Non-Goals:**

- No new `CargoSource` constructor and no overlay `dev-libs/rusty-v8` package.
- No host `rustc`/`gn` requirement for packing (clone+tar of rusty_v8 still runs in the materialize container).
- No automatic rebase of git-style `FILESDIR` hunks; system `protoc` is a template-owned `src_prepare` rewrite.

## Decisions

1. **Codex stays `CargoGitTag` with lock `codex-rs` and package `codex-rs/cli`.** Alternative: `CargoCratesIo` — rejected; there is no published `codex` crate that is the product, and the GitHub tag is the buildable workspace. Alternative: pycargoebuild at the virtual workspace root — rejected; existing policy already requires a package subdirectory when `[workspace]` has no `[package]`. `cli` is the `codex` binary package; `src_compile` still builds `--bin codex --bin codex-code-mode-host` from `S=codex-rs` in the human-owned ebuild.

2. **Arch allowlist lives on policy, not on `EcosystemSpec::Cargo`.** A small policy field (or parallel map keyed by `PackageKey`) listing allowed KEYWORDS arches (`["amd64"]` for Codex) is filtered in `lanesFromCeilings` / collapse / harvest-versus-ceiling. Alternative: rewrite KEYWORDS after collapse — rejected; harvest-versus-ceiling uses every selecting lane, so arm64 would still bind. Alternative: hardcoded exception in overlay write — rejected; planning would still emit arm64 outdated lines. hk/mise/usage/biodiff keep empty allowlist = all rust arches.

3. **`hasListEraCargoDeps` is true only when `CRATES` is non-empty.** That is the GitTag list-era signal. Empty `CRATES` plus `${CARGO_CRATE_URIS}` is the git-crates form and MUST NOT trigger the two-line rewrite. Extra `SRC_URI` lines that are not the primary archive or the crates tarball are preserved (jemalloc-style companion precedent in Go). Alternative: a Codex-only skip — rejected; the empty-`CRATES` rule is the honest list-era definition.

4. **Sidecar B is harvested from the lock’s `v8` pin, published under assets tag `rusty-v8-${ver}`, reused across Codex PVs.** Full-path always packs sidecar A (`{pn}-{pv}-crates.tar.xz`) from registry checksums (including the incomplete crates.io `v8` crate). Git crates stay `GIT_CRATES`. If `v8` is absent from the lock, skip B (hk path). Alternative: pack submodules into A — rejected; A is PV-keyed and would duplicate ~92 MiB on every Codex bump with a stable pin. Alternative: GitHub tag archive of rusty_v8 — rejected; archives omit submodules.

5. **Ebuild `[patch.crates-io] v8 = { path = … }` is template-owned `src_prepare`, not manager Haskell.** Manager publishes and names the snapshot; the ebuild unpacks it next to `S` and path-patches. Chromium clang 23 + rust-toolchain stay `SRC_URI` GCS lines in the same template (`Linux_x64` objects from rusty_v8 150.4.0 DEPS). When the `v8` pin changes, sidecar B harvest is new and the ebuild’s GCS filenames are human/template updates (or a later content fix) — not inferred from DEPS in v1.

6. **`T(pv)` reads lock-root `rust-toolchain.toml` `channel` only when it is dotted `X.Y.Z` and the active set has no `rust-version`.** This is general Cargo MSRV, not Codex-only. `stable`/`nightly` do not invent a floor. hk/mise/usage already declare `rust-version`, so their floors do not change. Written full-path floor remains `max(T, harvest)` so 1.95.0 is not dropped on the 0.153.4 bump.

7. **Windows-only git remotes are omitted from `GIT_CRATES` by target-table, not a name denylist.** Walk the same Linux-active set as MSRV; git packages reachable only through windows-only tables (Codex: `appcontainer_common` / mxc) are dropped. Alternative: hardcode `microsoft/mxc` — rejected; the next Windows-only git crate would leak back.

8. **System `protoc` is a `grep`+`sed` in template `src_prepare`, plus `BDEPEND` protobuf.** Marker missing → `die`. `protoc-bin-vendored-*` remain in sidecar A / lock so `--offline --locked` still resolves. Alternative: rewrite `Cargo.lock` in materialize — rejected; GitHub archive lock would disagree at emerge.

9. **No `string.rs` FILESDIR.** Codex’s lock uses bindgen 0.72.1, which emits `v8_String_WriteFlags_*` matching upstream. The 0.72.0 unprefixed names were a standalone rusty_v8 crate artifact.

10. **Human-owned ebuild body** (`S=`, V8 env, `CHECKREQS`, `RUST_MIN_STACK`, completions, bwrap, extra `SRC_URI`, `src_prepare`/`src_compile`/`src_install`) follows autolith/hk: pycargoebuild inplace plus manager field rewrites MUST NOT strip those constructs. `ensureCargoAssetsSrcUri` is the dangerous call site.

## Risks / Trade-offs

- [Gentoo `dev-build/gn` older than the CIPD gn used in the spike] → seed emerge is the gate; if ninja fails, pin a newer gn atom or add a gn distfile as a content revision. Do not block the lane on it.
- [LLVM slot other than 22] → ebuild pins `llvm-core/clang:22` and `LIBCLANG_PATH=…/lib64` (Chromium clang has no `libclang.so`; Gentoo `lib/` is i386).
- [Upstream moves the `protoc_bin_vendored::protoc_bin_path` marker] → `src_prepare` dies; operator updates the sed. No silent skip.
- [v8 pin change also needs new GCS clang/rust-toolchain filenames] → first bump 0.153.3→0.153.4 keeps 150.4.0; later pin changes may need a template content fix for GCS lines. Sidecar B harvest still runs.
- [GURU same atom] → overlay priority decides; no `package.mask`. Document coexistence in seed metadata only if Portage requires it.
- [Empty-`CRATES` SRC_URI rule regresses hk] → hk’s steady state is empty `CRATES` **after** rewrite, but list-era detection runs on pycargoebuild output which still has a `CRATES` list; tests must cover both hk (list-era → two-line) and Codex (already empty + GIT_CRATES → preserve).
- [rusty_v8 clone is ~1.1 GiB] → materialize disk floors already exist; sidecar B reuse avoids repeating it when the pin is stable.
- [Allowlist field on every policy] → default empty = current behavior; only Codex sets `["amd64"]`.

## Migration Plan

1. Manager: arch allowlist, `hasListEraCargoDeps`/`ensureCargoAssetsSrcUri`, MSRV `rust-toolchain.toml`, GIT_CRATES windows-omit, rusty_v8 sidecar harvest/reuse, `dev-util/codex` policy — `hk check`.
2. Merge spec deltas into `openspec/specs/` (`cargo-crates-assets`, `runtime-lanes`, new `dev-util-codex-seed`); `openspec validate --strict`.
3. Seed overlay 0.153.3: ebuild + `metadata.xml`; manual sidecar A and B in the materialize image; GCS clang/rust-toolchain in private distdir; `ebuild … manifest`; `gencache`; GPG-signed overlay and assets commits.
4. Acceptance: emerge `=dev-util/codex-0.153.3` (network-sandbox) and smoke version/help/completions; `outdated codex` reports `0.153.3 -> 0.153.4`; `update codex` publishes `codex-0.153.4` crates, reuses rusty_v8 `150.4.0`, preserves extra `SRC_URI` and `-* ~amd64`; emerge 0.153.4.
5. Rollback: revert overlay seed and policy line; Codex returns to undiscovered/`Unsupported`. Lane guards stay inert for packages without `v8` and without an allowlist.

## Open Questions

- Whether Gentoo `dev-build/gn` on the seed host is new enough for rusty_v8 150.4.0 ninja. Answer at seed emerge; fallback is a gn pin or distfile, not a lane redesign.
