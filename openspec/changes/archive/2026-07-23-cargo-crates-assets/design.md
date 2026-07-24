## Context

`update` already automates Go vendor, npm-cache, and bun-cache packages via `DepsAndAssets`: temp work → materialize or reuse assets release → rewrite overlay ebuild → `ebuild … manifest` → SHA512 verify → signed overlay commit (assets auto-push as today). Cargo packages `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` remain `Unsupported "cargo CRATES"` with list-era ebuilds (hundreds of `CRATES=` / Manifest DIST lines; `cargo.eclass` QA warns at ≥300 crates). Maintainers use **pycargoebuild** (Gentoo, not overlay Python helpers) to regenerate CRATES/LICENSE.

Constraints: quality gates (`hk check`); shell-out for Portage/`git`/`pycargoebuild`/fetchers is acceptable; pure Haskell for orchestration, hashing, ebuild field edits; GPG option B; **overlay auto-push out of scope**; assets auto-push unchanged.

## Goals / Non-Goals

**Goals:**

- `DepsAndAssets Cargo` on the shared spine (assets tarball, not CRATES lists)
- Shell **`pycargoebuild --crate-tarball`** for pack + CRATES/LICENSE; manager owns SRC_URI, `RUST_MIN_VER`, KEYWORDS
- Distfile `{pn}-{pv}-crates.tar.xz` on `mndz-overlay-assets`; release tag `{pn}-{pv}`
- Rust multi-lane: ceilings U1 **max** of gentoo `dev-lang/rust` ∪ `dev-lang/rust-bin`; labels `dev-lang/rust|rust-bin`
- MSRV: root `rust-version` → max crate `rust-version`s on full path → donor `RUST_MIN_VER` (no lower) → hard-fail
- Enable hk / mise / usage; **M2** migrate overlay to tarball `-r1` + publish crates assets in this change
- Preflight pycargoebuild + wget/aria2 when cargo packages selected; no host rustc for pack

**Non-Goals:**

- Reimplement pycargoebuild in Haskell
- Keep CRATES-list packaging as a supported steady-state mode
- Overlay auto-push
- First-import empty package dirs; live `9999`
- Host `cargo check` / compile smoke tests
- MSRV from Gentoo “current stable rust” keyword tips (S3) as primary policy
- Dual long-term support of list-era ebuilds after migration

## Decisions

### Decision: Technique shape — `DepsAndAssets Cargo`

Extend `EcosystemSpec` with Cargo (not a parallel technique). `techniqueNeedsAssets` true.

Optional fields (names illustrative):

| Field | Role | hk / mise | usage |
|-------|------|-----------|--------|
| Lock root | Directory with `Cargo.lock` (may be workspace root) | root | root |
| Package subdir / pycargoebuild cwd | Binary `Cargo.toml` / `rust-version`; also `pycargoebuild` directory when set (workspace members — tool rejects workspace roots) | root | `cli` |

**Rationale:** Same plan → reuse/full → publish → overlay → verify → commit spine as Go/JS.  
**Alternatives:** Dedicated `CargoCratesAndAssets` technique — rejected (two spines). CRATES-list-only technique — rejected (Manifest size, no assets reuse).

### Decision: Shell pycargoebuild; do not reimplement

Full path (temp dir):

```text
clone GitHub @ tagPrefix+PV
copy/rename donor ebuild for this PV
pycargoebuild -c -i <ebuild> -M -f \
  --crate-tarball-path <work>/{pn}-{pv}-crates.tar.xz \
  --crate-tarball-prefix cargo_home/gentoo \
  [-d <temp-distdir>] \
  <lock-root>
manager: SRC_URI, RUST_MIN_VER, KEYWORDS
publish asset (unless reuse)
ebuild … manifest → SHA512 verify → overlay commit
```

**Rationale:** ~1.5k LOC + license mapping already maintained upstream; Go/JS precedent is “orchestrate tools,” not rehost Gentoo helpers.  
**Alternatives:** Full Haskell port — rejected for ROI; call overlay Python — N/A (no cargo helper there).

### Decision: Crate tarball + assets (not CRATES list)

Empty `CRATES` + one distfile; consumers fetch from assets (like vendor/deps). Internal layout `cargo_home/gentoo` for `cargo.eclass`.

**Rationale:** mise/hk already past eclass ≥300 QA; aligns with existing assets investment; small overlay diffs.  
**Alternatives:** CRATES list automation — rejected for Manifest noise and weak reuse.

### Decision: Naming

| Item | Value |
|------|--------|
| Distfile | `{pn}-{pv}-crates.tar.xz` (overlay PN/PV; manager passes `--crate-tarball-path`) |
| Release tag | `{pn}-{pv}` |
| Kind | `CratesDist` (alongside Vendor / Deps) |
| SRC_URI assets | `…/releases/download/{pn}-${PV}/{pn}-${PV}-crates.tar.xz` |

**Rationale:** pycargoebuild default uses Cargo.toml name/version; overlay must always use PN. Suffix `-crates` distinct from npm `-deps`.

### Decision: Field ownership

| Field | Owner |
|-------|--------|
| `CRATES` (empty under `-c`) | pycargoebuild |
| Crate `LICENSE+=` | pycargoebuild |
| `SRC_URI` (source + assets crates) | manager |
| `RUST_MIN_VER` | manager (eclass expands to `\|\| ( rust-bin rust )` BDEPEND — same pattern as guru `dev-util/tokei`) |
| `KEYWORDS` | manager (lane plan) |
| `src_*`, IUSE, completions, extra DEPEND/BDEPEND | human |

Rewrite order **O1**: pycargoebuild `-i` first, then manager patches.

### Decision: Runtime ceilings — U1 max union

Per arch × plain/tilde:

```text
ceiling = max( tip(dev-lang/rust), tip(dev-lang/rust-bin) )
```

Both packages from gentoo via `portageq get_repo_path`. Missing side ignored for that lane.

**Labels:** fixed `(dev-lang/rust|rust-bin amd64)` / `(dev-lang/rust|rust-bin ~arm64)` (L2).

**Rationale:** Matches eclass `|| ( rust-bin rust )` — user needs either provider; max is correct availability.  
**Alternatives:** min(rust, rust-bin) — rejected (AND-like, understates rust-bin-ahead). Single package only — weaker.

### Decision: Candidates, prune, multi-PV

Same as other `DepsAndAssets`: local non-live ∪ upstream newer than max local; zero planned PVs hard-fail; exact-set prune non-live extras; leave live untouched. No host rustc gate on full path (pycargoebuild does not invoke rustc/cargo).

### Decision: MSRV / requirement probe

Version compare: normalize to N.N.N (`1.91` → `1.91.0`); strip noise like `_p*` on ceiling PVs for tuple compare (C1+N2).

```text
1. package.rust-version at packageSubdir (or root) if set
2. else max of package.rust-version over Cargo.lock packages + workspace
   members readable on full path (after crate fetch / clone)
3. combine with donor ebuild RUST_MIN_VER via max() when donor exists
   (never lower a higher known floor)
4. if still nothing → hard-fail
```

When root `rust-version` is set, still take **max(root, max-deps, donor)** so transitive MSRV (tokei-style “deps need newer rust”) is not under-declared.

Write result as `RUST_MIN_VER="…"`. Reuse path does **not** re-scan crates (P-never); keep ebuild value unless content repair needs a new full path.

**Rationale:** `rust-version` is optional in Cargo; usage lacks it; max-deps beats Gentoo keyword S3 for lock-correlated churn.  
**Alternatives:** S3 plain min-arch — demoted (keyword churn, not true MSRV). H1-only — blocks usage without donor.

### Decision: Needs-work and reuse

**Needs-work** when any of: missing ebuild for planned PV; KEYWORDS ≠ plan; `RUST_MIN_VER` ≠ probed/stamped policy; SRC_URI not assets-crates form / list-era `CARGO_CRATE_URIS` dep pattern; non-empty CRATES; Manifest missing crates DIST; SHA512 mismatch when known.

**Reuse (R2):** assets release has `{pn}-{pv}-crates.tar.xz` and downloaded bytes match expected SHA512 → skip pack and publish; manager may still fix KEYWORDS/RUST_MIN_VER/SRC_URI; **no pycargoebuild (P-never)**.

**Full path:** pack + publish + O1 rewrite.

### Decision: Preflight P1

If any selected package is `DepsAndAssets Cargo`, require `pycargoebuild` and at least one of `wget`/`aria2c` before work (even if all units later reuse). Message points at install (`uv`/`pipx` or `app-portage/pycargoebuild`). Do not pin exact 0.16 in code unless breakage forces it; document known-good in README.

### Decision: Git crates G2

No manager ban. pycargoebuild success/failure is the oracle (supported git hosts only).

### Decision: M2 migration (this change)

Operator/agent bootstrap, not first consumer `update` discovery:

1. Land manager + policy  
2. For each of hk, mise, usage current PV: full materialize + assets publish  
3. Overlay: tarball-shaped ebuilds as **`{pn}-{pv}-r1.ebuild`**, Manifest, md5-cache, signed commits  
4. Steady-state: `mndz-overlay-manager update`  

Publish assets before or with ebuilds that reference them (no broken SRC_URI window).

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| pycargoebuild version skew (0.15 tree vs 0.16 uv) | Document known-good; fail with clear stderr |
| Large mise crate tarball / GH release size | xz -9; monitor size once at M2 |
| Sparse `rust-version` under-declares MSRV | max-deps + donor max; tokei-style human raise still possible via donor |
| Git crate pack failure | G2 unit hard-fail with tool message |
| Assets SPOF vs crates.io | Same trust model as Go vendor / npm-cache |
| M2 coordination overlay + assets + manager | Tasks sequence: implement → bootstrap publish → overlay -r1 → hk check |

## Migration Plan

1. Implement Cargo ecosystem in manager; tests green; `hk check`  
2. Bootstrap: publish crates for current hk/mise/usage PVs; commit assets  
3. Overlay: replace list-era ebuilds with `-r1` tarball style; Manifest; gencache; signed commits  
4. Verify `outdated`/`update` plan/reuse on one package  
5. Rollback: revert overlay to previous commits; assets releases can remain (harmless orphans)

## Open Questions

None blocking. Optional later: policy explicit `rustMinVer` override map; dev-dep exclusion in max-deps graph.
