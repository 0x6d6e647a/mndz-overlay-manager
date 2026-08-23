## Context

See `proposal.md` for motivation. `renderMaterializeDockerfile` emits `(emerge -n ">=…-bin-<ver>" || emerge -n ">=…-<ver>")` with no gentoo KEYWORDS check except bun-bin `dev-lang/bun-bin::mndz ~<arch>`. `neededFloorsFromClassified` takes `max(ltGoReq)` over **every** lane of a package that has any full-path unit. `FEATURES=getbinpkg`; `/var/cache/binpkgs` is cache-mounted without `buildpkg`, `--usepkg`, or a stable `id=`. Generator id is `mndz-overlay-manager-materialize-2`. Ceiling discovery already walks gentoo `dev-lang/go`, `nodejs`, `rust` ∪ `rust-bin`, `dev-lisp/sbcl` (`RuntimeEbuildMeta` + KEYWORDS). Overlay bun-bin metas are re-read at ensure (`readOverlayBunFloor`). Overlay Cargo writes `RUST_MIN_VER`; `rust.eclass` expands `|| ( rust-bin rust )`. `virtual/rust` is last-rited.

## Goals / Non-Goals

**Goals:**

- Pure resolve: one atom + optional `>=VER::repo ~arch` from metas, host KEYWORDS token, and floor.
- Recipe render takes resolved installs; no shell `||`.
- Full-path PV reqs only for this-prepare floors; union with sidecar unchanged.
- `buildpkg` + `usepkg` + stable cache `id=`; generator `…-3`.
- Fake-docker / pure tests only in `hk check`.

**Non-Goals:**

- PKGDIR prune (`binpkg-prune-handoff.md`).
- Overlay consumer unmask; changing BDEPEND/`RUST_MIN_VER`/lane union.
- `exposed-modules` / weeder `root-modules` expansion.
- Live Gentoo `docker build` in CI.

## Decisions

### D1: Resolve in Haskell from existing metas

Add a pure helper (e.g. `Update.Materialize.Resolve` as `other-modules`) that, given host arch token, floor, `-bin` metas, and source metas, returns `Either` miss `ResolvedToolchain` `{ atom, emergeSpec, maybeAcceptLine }`.

Order: if `-bin` dir has a host-arch ebuild ≥ floor (tilde **or** plain), pick `-bin`; else source with the same check; else `Left`. Prefer `-bin` even when that forces `~arch` and source would be plain-visible (Cargo lanes already union the two; compiling `dev-lang/rust` to avoid a tilde is the expensive choice).

Plain-visible: some ebuild of the **chosen** atom with `keywordsHasBare` and PV ≥ floor. If not, accept line `>=cat/pkg-floor::repo ~arch`. Floor token `"0"` / empty: unversioned emerge spec; `~arch` only if no plain host-arch ebuild exists at all.

- *Alternative — shell `||`:* Rejected; `sbcl-bin` does not exist; masks after the fallback.
- *Alternative — prefer plain source over testing `-bin`:* Rejected; rust-bin unpack vs rust compile.
- *Alternative — `virtual/rust`:* Rejected; last-rited; eclass `||` is overlay-only.

Ensure generate path: `portageq get_repo_path` + `discoverRuntimeMetasInDir` for go / go-bin, nodejs / nodejs-bin, rust / rust-bin, sbcl / sbcl-bin (missing `-bin` dir → empty metas, not a hard-fail). Bun stays overlay metas. Miss on a **needed** toolchain → `Left` before `docker build` (`unmappedArchMessage` style).

### D2: Recipe input is resolved installs, not floor+guessed atoms

`renderMaterializeDockerfile` takes the arch, overlay path, and the list of resolved toolchain RUNs (rust+pycargoebuild, sbcl+quicklisp, node, go, bun) rather than calling `emergeBinThenSrc`. Each gentoo toolchain RUN: cache mounts, optional `mkdir` + `printf` accept_keywords, `emerge -n "<spec>"`. SBCL: no `[source]`. Keep layer order rust → sbcl → node → go → bun.

Bun accept line becomes `>=dev-lang/bun-bin-<pv>::mndz ~<arch>` when not plain-visible (overlay bun-bin is tilde-only today).

### D3: This-prepare floors from classified full-path PVs

Change `neededFloorsFromClassified` so each `Full*` `ClassifiedPvUnit` contributes that **PV**’s req: look up `glpLanes` for `ltPackagePV == cpuPV`, take `ltGoReq` (same req on every lane for that PV). Union those plus overlay bun-bin when any Bun unit is full-path. Do not use `maxReqFromPlan` over unused lanes. Sidecar `unionFloors` on build unchanged.

- *Alternative — whole-plan max:* Rejected; reuse sibling 1.26.5 must not force testing Go when this run vendors 1.24.

### D4: `buildpkg` / `usepkg` / stable cache id

`FEATURES` adds `buildpkg` (keep `getbinpkg` and sandbox disables). `EMERGE_DEFAULT_OPTS` adds `--usepkg` (keep `--quiet-build=y --with-bdeps=n`; `--buildpkg` may duplicate FEATURES — prefer FEATURES + `--usepkg` only). Cache mounts:

```
--mount=type=cache,id=mndz-materialize-distfiles,target=/var/cache/distfiles
--mount=type=cache,id=mndz-materialize-binpkgs,target=/var/cache/binpkgs
```

Do **not** change these ids later (prune follow-up included). Do not `eclean` in this change.

### D5: Generator `mndz-overlay-manager-materialize-3`

Satisfy still requires id + floors + `isGenerator == materializeGeneratorId`. Bump the constant so `-2` images rebuild with resolved atoms and `usepkg` flags.

### D6: Tests stay fake-docker

Extend `Test.Ensure` (and a small resolve unit group): no `sbcl-bin ||` in rendered text; SBCL testing floor emits `::gentoo ~amd64` and a single `dev-lisp/sbcl` emerge; rust-bin chosen over plain rust; bun-bin line has `::mndz` and version; ppc64le still `~ppc64`; full-path-only floor vs reuse sibling; missing metas → ensure `Left` without `docker build`; generator mismatch rebuilds. Fake ebuild trees like `Test.Lanes`. No live Hub/`emerge` in `hk check`.

### D7: README in the same change

Materialize section: Portage `-bin` when available; per-atom `~arch` not whole-image `ACCEPT_KEYWORDS`; local binpkg reuse. Do not document PKGDIR prune.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| SBCL *deps* also `~amd64` | Per-atom unmask of sbcl only; today’s failure listed only sbcl. Hard-fail if emerge still masks; no `--autounmask` in this change |
| rust-bin / rust blockers if both installed | Recipe emerges exactly one atom |
| First SBCL compile still long | Intended; `usepkg` helps the *next* generator rebuild |
| Stable cache `id=` vs Dockerfile text | `id=` is independent of recipe hash; keep constant |
| `builder prune` wipes PKGDIR | Existing spec forbids prune-all / builder prune in ensure; operator-initiated prune remains a cold start |
| go-bin / nodejs-bin missing | Empty `-bin` metas → source atom; tests cover missing dir |
| Floor `"0"` | Unversioned atom; `~arch` only if no plain ebuild |

## Migration Plan

- Operators with a `-2` sidecar: next full-path `update` rebuilds (`-3`).
- Warm PKGDIR after the first successful `-3` build: later generator rebuilds should `usepkg` the same PVs.
- `MNDZ_MATERIALIZE_IMAGE` users: unchanged (inspect-only).
- Rollback: revert; shell `||` and SBCL mask return.

## Open Questions

None. PKGDIR old-version cleanup is `binpkg-prune-handoff.md`.
