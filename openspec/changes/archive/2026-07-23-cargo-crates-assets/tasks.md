## 1. Types and naming

- [x] 1.1 Extend `EcosystemSpec` with `Cargo` (optional lock/package subdirs) and update `techniqueNeedsAssets`, ecosystem predicates, and related exports
- [x] 1.2 Add `CratesDist` (or equivalent) to `DistfileKind` and `{pn}-{pv}-crates.tar.xz` naming in `Update.Assets.Layout`
- [x] 1.3 Wire layout/apply/check call sites so Cargo uses crates distfile names and release tags `{pn}-{pv}`

## 2. Policy

- [x] 2.1 Change hardcoded policy for `dev-util/hk`, `dev-util/mise`, `dev-util/usage` from `Unsupported "cargo CRATES"` to `DepsAndAssets Cargo` with GitHub sources; set usage package subdir `cli` as designed
- [x] 2.2 Update unit tests that assert mise/hk/usage techniques

## 3. Runtime lanes (rust ∪ rust-bin)

- [x] 3.1 Discover ceilings from gentoo `dev-lang/rust` and `dev-lang/rust-bin`; implement U1 max per arch×tier
- [x] 3.2 Set cargo lane labels to `dev-lang/rust|rust-bin` (+ arch/tier)
- [x] 3.3 Integrate cargo into shared `Deps.Plan` / check path (candidates, lane targets, KEYWORDS collapse, exact-set prune)
- [x] 3.4 Tests for U1 max when one provider is ahead; empty/missing runtime dir errors

## 4. MSRV probe

- [x] 4.1 Parse and normalize `package.rust-version` to N.N.N; compare against ceiling PVs (strip `_p*` noise as designed)
- [x] 4.2 Full-path max of crate/workspace `rust-version`s; combine with root and donor via max; hard-fail if none
- [x] 4.3 `EbuildEdit` ensure/replace `RUST_MIN_VER`; content-fix includes MSRV + SRC_URI crates form + empty CRATES / no list-era dep URIs
- [x] 4.4 Unit tests for normalize, max-deps vs donor, missing-all hard-fail

## 5. Materialize full path (pycargoebuild)

- [x] 5.1 Temp clone at tag; temp distdir; invoke `pycargoebuild -c -i -M -f` with manager tarball path and `cargo_home/gentoo` prefix
- [x] 5.2 After tool: manager rewrites SRC_URI (source + assets crates URL), `RUST_MIN_VER`, KEYWORDS (O1)
- [x] 5.3 Surface tool failures (including git crate / unsupported sources) as unit hard-fail with stderr context
- [x] 5.4 Progress sub-phase labels for cargo full path (clone, pycargoebuild, publish, manifest) consistent with cli-activity patterns

## 6. Reuse path and apply spine

- [x] 6.1 Reuse R2: lookup release asset, download, SHA512 verify; skip pycargoebuild and publish (P-never)
- [x] 6.2 Shared publish → overlay commit → Manifest verify spine for crates distfiles (parity with vendor/deps)
- [x] 6.3 Same-PV repair and needs-work checklist for cargo (including list-era regression detection)

## 7. Preflight and CLI

- [x] 7.1 Preflight P1: when any selected package is Cargo, require `pycargoebuild` and wget/aria2 (or aria2c); assets/`xz`/token as for other DepsAndAssets
- [x] 7.2 Outdated/update lane reporting for cargo packages (union labels, crates DIST adequacy)
- [x] 7.3 README: document `pycargoebuild` + fetcher as conditional cargo tools; light CONTRIBUTING/AGENTS touch only if needed per project-docs

## 8. Tests and quality

- [x] 8.1 Cabal tests for policy, naming, MSRV, ceiling union, content-fix helpers
- [x] 8.2 Run `hk check` (or full pipeline) and fix issues

## 9. M2 bootstrap (overlay + assets)

- [x] 9.1 Full materialize + publish crates tarballs for current hk, mise, and usage PVs to mndz-overlay-assets
- [x] 9.2 Migrate overlay ebuilds to tarball shape as `-r1` (empty CRATES, assets SRC_URI, managed RUST_MIN_VER/KEYWORDS); preserve human `src_*`/IUSE/completions
- [x] 9.3 Regenerate Manifests and package md5-cache; signed overlay commits (no overlay auto-push unless requested)
- [x] 9.4 Smoke `outdated` / `update` against one cargo package (reuse path preferred after bootstrap)
