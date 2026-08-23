## Why

Ensure’s generated Dockerfile trial-emerges `dev-lisp/sbcl-bin` (no such package) then `>=dev-lisp/sbcl-<floor>` on a **stable** stage3. Autolith’s `sbcl.version` floor is testing (`~amd64`); Portage masks it and the shared image build fails for every full-path unit (dolt, autolith, hk, …). Haskell already scans gentoo for lane ceilings; the recipe must use that tree to pick **one** atom and `~{{arch}}` **before** `docker build`. Self-built binpkgs must land in the existing PKGDIR cache mount so a later layer invalidation does not recompile Go/Node/Bun.

## What Changes

- **Resolve emerge atoms in Haskell.** For each toolchain this prepare needs, scan gentoo (same package dirs as ceiling discovery). If a `-bin` cat/pkg exists and has a host-arch ebuild ≥ floor (plain or tilde), emerge that atom; otherwise the source package. One `emerge`, no shell `(emerge bin || emerge src)`. Missing both → hard-fail ensure before `docker build`. Image SBCL does **not** use `USE=source`. Overlay ebuilds stay as specified (`RUST_MIN_VER` + eclass `|| ( rust-bin rust )`, `>=dev-lang/go-…`, `>=dev-lisp/sbcl-…:=[source]`). No `virtual/rust`.
- **Per-atom `package.accept_keywords` when the floor is not plain-visible** on the host KEYWORDS token (`raKeywords`: `amd64`, `arm64`, `ppc64`, …). Line form `>=cat/pkg-VER::repo ~{{arch}}` (`::gentoo` for tree toolchains, `::mndz` for bun-bin). Still no whole-image `ACCEPT_KEYWORDS=~arch`.
- **This-prepare floors are full-path units only** (max req of classified `Full*` PVs), then **union** with previous `image.json` (option 2; never drop a paid toolchain).
- **`buildpkg` + `usepkg`** on the existing `/var/cache/binpkgs` cache mount, plus a **stable** mount `id=` so generator rebuilds reuse PKGDIR. Keep `getbinpkg` (official binhost). Do **not** prune old PKGDIR versions in this change.
- **Generator identity** becomes `mndz-overlay-manager-materialize-3` (rebuild existing `:local` images).
- README: image Portage prefers `-bin`, accepts testing toolchain atoms per-package when the floor requires it, and reuses local binpkgs across builds.

### Non-goals

- PKGDIR old-version prune (wiki `binpkg-prune-handoff.md`, change name `materialize-binpkg-prune`)
- Overlay-side `package.accept_keywords` for consumers of gentoo BDEPEND/RDEPEND (keep `::mndz` testing-third-party)
- Whole-image `ACCEPT_KEYWORDS=~arch`; official go.dev/nodejs.org/GitHub zip toolchains
- Overlay-union or always-all-five toolchains; this-prepare-only without union
- Changing overlay KEYWORDS, BDEPEND/RDEPEND, `RUST_MIN_VER`, or runtime-lane ceiling union
- `USE=source` on image SBCL; `virtual/rust`
- `docker builder prune`; `eclean-pkg --deep` at the start of a from-scratch build
- Host-path materialize (`host-materialize-fallback`); QEMU / foreign-arch; publishing a registry image

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `ensure-materialize-image`: Haskell-resolved toolchain atom (`-bin` then source); per-atom `>=VER::repo ~{{arch}}` when the floor is not plain-visible; floors from full-path classified PVs ∪ previous sidecar; `buildpkg`/`usepkg` + stable PKGDIR cache id; generator `…-3`
- `project-docs`: README describes Portage `-bin` preference, per-atom testing keywords, and local binpkg reuse for the generated image

## Impact

- **Code:** `Update.Materialize.Recipe` (no `emergeBinThenSrc` shell `||`); new pure resolve (atom + maybe accept_keywords) from gentoo metas + host arch + floor; `neededFloorsFromClassified` / `floorsForPlan` use full-path PV reqs not `maxReqFromPlan` of every lane; `FEATURES`/`EMERGE_DEFAULT_OPTS` and cache `id=`; `materializeGeneratorId`
- **Tests:** Recipe has a single emerge atom, no `sbcl-bin ||`; accept_keywords line includes `::gentoo`/`::mndz` and `~amd64`/`~ppc64` as mapped; bun-only omits SBCL; full-path-only floor vs reuse PV; generator mismatch rebuilds
- **Docs:** `README.md` materialize section
- **Operator:** First full-path `update` after this change rebuilds `:local`. Testing SBCL/Go/Rust floors should emerge instead of mask. First compile of a new PV is still slow; later generator rebuilds should `usepkg` when PKGDIR is warm
