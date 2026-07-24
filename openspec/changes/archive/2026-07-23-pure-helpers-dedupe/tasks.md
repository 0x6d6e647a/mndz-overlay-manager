## 1. Version helpers

- [x] 1.1 Add `renderPVNoRev` and `eqPV` (or `samePV`) to `Overlay.Version` with Haddocks
- [x] 1.2 Replace duplicate definitions in Apply, Check, Deps.Plan, and Go.Plan; update imports
- [x] 1.3 Replace local `samePV` where-clauses in Apply, Check, EbuildEdit, Go.Lanes with the shared helper where appropriate

## 2. HTTP catch helper

- [x] 2.1 Export a single `tryHttp` / `catchHttp` helper (prefer `Update.Http` or a leaf module if cycles appear)
- [x] 2.2 Rewire GitHub, Http, Npm, Npm.Cache, Assets.Release, Go.ModFetch to use it; delete local copies

## 3. Quote strip and Cargo MSRV

- [x] 3.1 Extract shared quote-strip helper; rewire Cargo.Msrv, Go.Tree, EbuildEdit
- [x] 3.2 Unify Cargo MSRV fetch used by Check and Apply (optional donor content as parameter if needed)

## 4. Verify

- [x] 4.1 `cabal test all` green
- [x] 4.2 `hk check` green
- [x] 4.3 Grep confirms no remaining duplicate `renderPVNoRev` / local `tryHttp` definitions outside the shared homes

## 5. Specs and handoff

- [x] 5.1 Keep `ebuild-version` delta aligned with the shared helpers
- [x] 5.2 Sync `ebuild-version` into main specs at archive
- [x] 5.3 Ready to archive; next change: `runtime-naming-cleanup`
