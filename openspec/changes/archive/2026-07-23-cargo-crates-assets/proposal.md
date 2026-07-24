## Why

Go, npm, and Bun packages already ride the shared `DepsAndAssets` spine (materialize → assets publish/reuse → overlay rewrite → Manifest → signed commit), with multi-PV runtime lanes. The remaining overlay packages—`dev-util/hk`, `dev-util/mise`, and `dev-util/usage`—are still `Unsupported "cargo CRATES"`: they use giant `CRATES=` lists (hundreds of DIST lines; mise alone ~958) maintained via manual `pycargoebuild`, and never use `mndz-overlay-assets`. Closing cargo with the same assets-first model (crate tarball + lanes from Gentoo rust toolchains) finishes automated `update` coverage for the known mndz overlay set.

## What Changes

- Extend `EcosystemSpec` / `DepsAndAssets` with **`Cargo`** (optional package/lock subdir fields as needed for workspaces such as usage’s `cli/`)
- Full-path materialize by **shelling out to `pycargoebuild`** (`--crate-tarball`, inplace ebuild update, no-manifest): pack `{pn}-{pv}-crates.tar.xz` with internal prefix `cargo_home/gentoo`; work in a **temp dir** (not Portage DISTDIR). **Do not** reimplement pycargoebuild in Haskell
- Publish/reuse crates tarballs on **`mndz-overlay-assets`** (release tag `{pn}-{pv}`, same auto-push rules as Go/JS); distfile kind **`CratesDist`** / basename `{pn}-{pv}-crates.tar.xz` (always overlay PN/PV)
- Manager owns **SRC_URI** (source + assets crates URL), **RUST_MIN_VER**, and **KEYWORDS**; pycargoebuild owns empty **CRATES** and crate **LICENSE+=**; human owns `src_*` / IUSE / completions / extra deps
- **Rust multi-lane** planning: ceilings = per-arch plain/tilde **U1 max** of gentoo `dev-lang/rust` ∪ `dev-lang/rust-bin`; candidates and exact-set prune same as other `DepsAndAssets`; labels use fixed union id `dev-lang/rust|rust-bin`
- **MSRV probe**: prefer package `rust-version` (policy package subdir); else **max declared `rust-version` over lock/workspace crates** on full path; else donor ebuild `RUST_MIN_VER` (do not lower a higher donor); else hard-fail. Normalize to N.N.N. No host `rustc` gate for packing
- Enable policy for **hk**, **mise**, **usage** (`DepsAndAssets Cargo`, existing GitHub sources)
- **M2 bootstrap (this change)**: migrate the three overlay packages to tarball-shaped ebuilds as **`-r1`** of current PVs, publish crate tarballs to assets, Manifest/md5-cache/signed overlay commits; thereafter steady-state is `update`
- Preflight **P1**: if any selected package is cargo `DepsAndAssets`, require `pycargoebuild` and a fetcher (`wget` and/or `aria2c`)
- Reuse **R2** (download + SHA512); **P-never** (no pycargoebuild on clean reuse); rewrite order **O1**; same-PV repair in scope; git crates **G2** (pass-through to pycargoebuild)
- README: document cargo operator tools (`pycargoebuild`, fetcher)

## Capabilities

### New Capabilities

- `cargo-crates-assets`: Cargo ecosystem under `DepsAndAssets`: pycargoebuild crate-tarball materialize, distfile naming, MSRV probe (root + max-deps + donor), SRC_URI/`RUST_MIN_VER` ownership, policy for hk/mise/usage, preflight tools, reuse vs full path

### Modified Capabilities

- `deps-assets`: Add `Cargo` to ecosystem specs; `techniqueNeedsAssets` true for cargo; distfile naming includes `-crates.tar.xz`
- `runtime-lanes`: Cargo ceilings from gentoo `dev-lang/rust` ∪ `dev-lang/rust-bin` (U1 max per lane); lane labels `dev-lang/rust|rust-bin`; MSRV requirement compare for lane targets
- `assets-publish`: Crates tarball asset names and release layout parity with vendor/deps
- `update-apply`: Dispatch cargo full/reuse paths; hardcoded policy leaves `Unsupported "cargo CRATES"`
- `update-command` / `outdated-command` / `cli-help`: Cargo in preflight/reporting/help where operator-facing
- `project-docs`: README runtime tools for cargo (`pycargoebuild`, wget/aria2); CONTRIBUTING/AGENTS only if operator-runtime section already lists go/npm/bun

## Impact

- **Code**: `Update.Types`, `Update.Hardcoded`, `Update.Apply`, `Update.Check`, `Update.Preflight`, `Update.Deps.Plan`, `Update.EbuildEdit`, `Update.Assets.Layout`, new cargo materialize/MSRV modules; tests for naming, MSRV normalize/max, ceiling union
- **External tools**: **`pycargoebuild`**, **wget** and/or **aria2c** on cargo full path; no host `rustc`/`cargo` required for packing
- **Runtime trees**: gentoo `dev-lang/rust` and `dev-lang/rust-bin` for ceilings
- **Packages**: `dev-util/hk`, `dev-util/mise`, `dev-util/usage` enabled; overlay ebuilds migrate to empty CRATES + assets crates SRC_URI as `-r1`
- **Assets repo**: new `{pn}-{pv}-crates.tar.xz` releases (auto-push as today for assets only)
- **Non-goals**: reimplement pycargoebuild; CRATES-list packaging mode; overlay auto-push; first-import empty dirs; live `9999`; dual forever-support of list-era ebuilds; host compile smoke tests; tracking Gentoo stable rust as MSRV (S3)
