## 1. Resolve and floors

- [x] 1.1 Pure `Update.Materialize.Resolve` (`other-modules`): from host KEYWORDS token, floor, `-bin` metas, source metas → one atom + emerge spec + optional `>=VER::repo ~arch`; prefer `-bin` when a host-arch ebuild ≥ floor exists (plain or tilde); miss if neither package can meet the floor; floor `"0"` unversioned; no `USE=source`
- [x] 1.2 `neededFloorsFromClassified` uses each classified full-path PV’s lane req (`ltGoReq` for that PV), not `maxReqFromPlan` over unused lanes; reuse/GitMv units do not contribute
- [x] 1.3 Tests: rust-bin chosen over plain rust; sbcl with no `-bin` dir picks `dev-lisp/sbcl` and `::gentoo ~amd64` when only tilde; missing ebuilds ≥ floor is a miss; full-path 1.24 + reuse 1.26 → Go floor 1.24

## 2. Recipe and ensure

- [x] 2.1 `renderMaterializeDockerfile` takes resolved installs; delete shell `emergeBinThenSrc`; bun-bin accept line is `>=dev-lang/bun-bin-<pv>::mndz ~<arch>`; SBCL RUN has no `[source]` and no `sbcl-bin`
- [x] 2.2 `FEATURES` includes `buildpkg`; `EMERGE_DEFAULT_OPTS` includes `--usepkg`; distfiles/binpkgs cache mounts use stable `id=mndz-materialize-distfiles` and `id=mndz-materialize-binpkgs`
- [x] 2.3 Ensure generate path loads gentoo metas (missing `-bin` dir = empty, not fail) and fails before `docker build` when resolve misses; bump `materializeGeneratorId` to `mndz-overlay-manager-materialize-3`
- [x] 2.4 Tests: rendered SBCL testing floor has one emerge and `>=dev-lisp/sbcl-2.6.6::gentoo ~amd64`; bun `::mndz` versioned line; ppc64le still `~ppc64`; no `sbcl-bin ||`; generator mismatch rebuilds; resolve miss does not invoke `docker build`

## 3. Docs and quality gate

- [x] 3.1 README materialize section: Portage `-bin` when available; per-atom `~arch` not whole-image `ACCEPT_KEYWORDS`; local binpkg reuse
- [x] 3.2 `openspec validate --change materialize-toolchain-portage --strict`
- [x] 3.3 `hk check` green; no weeder/stan weakening; no `exposed-modules` expansion unless the test-suite requires it
