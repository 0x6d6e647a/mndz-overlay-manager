## 1. Dependencies and module skeleton

- [x] 1.1 Add HTTP and JSON dependencies to `mndz-overlay-manager.cabal` (library + executable as needed)
- [x] 1.2 Create module stubs: `Overlay.Version`, `Update.Types`, `Update.Infer`, `Update.Hardcoded`, `Update.Resolve`, `Update.GitHub`, `Update.Npm`, `Update.Http`, `Update.Check`; export from cabal

## 2. Ebuild version

- [x] 2.1 Implement `EbuildVersion` (numeric components + optional revision, raw), parse, and pretty-render (`v…`, optional `-rN`)
- [x] 2.2 Implement PV comparison (ignore revision; numeric component order; incomparable for raw mixes)
- [x] 2.3 Add hand-rolled unit tests for parse, render, and compare cases from the ebuild-version spec

## 3. Update sources and resolve

- [x] 3.1 Define `UpdateSource` ADT (GitHub / Npm / Http), `PackageKey`, report/status types in `Update.Types`
- [x] 3.2 Implement hardcoded map with `dev-util/grok-build-bin` Http stable + fallback
- [x] 3.3 Implement Level-1 expander (simple assignments, `${PN}`, `${PV}`, `${P}`, `${PN//-bin/}`, `${VAR}`)
- [x] 3.4 Implement inference matchers: ignore assets repo; npm first; GitHub tag/release + prefix; return `Maybe UpdateSource`
- [x] 3.5 Implement `resolve` = hardcoded ∨ infer from ebuild path/text + package context
- [x] 3.6 Add hand-rolled tests for expander and inference using fixture ebuild snippets (dolt, bun vars, openspec npm, assets-only)

## 4. Fetchers

- [x] 4.1 Implement Http fetcher (primary then fallback; strip body; timeout)
- [x] 4.2 Implement GitHub fetcher (`releases/latest`, tag prefix strip; optional `GITHUB_TOKEN`; tags fallback with max PV)
- [x] 4.3 Implement npm fetcher (registry `…/latest` version field)
- [x] 4.4 Define injectable `Fetcher` (or client record) used by check logic for tests

## 5. Check pipeline

- [x] 5.1 Group discovered ebuilds by `category/package`, select newest local PV, attach ebuild path for inference
- [x] 5.2 Implement `checkOverlay`: resolve → fetch → compare → `UpdateReport` list (Outdated / Ok / Ahead / Unconfigured / Error)
- [x] 5.3 Add hand-rolled tests with injected fetcher covering outdated, ok, ahead, unconfigured, fetch error

## 6. CLI `outdated`

- [x] 6.1 Add `Outdated` to `CLI.Parser` command set and help metadata
- [x] 6.2 Wire `Main`: same spine as `list` (config, path, validate, discover, empty = error); call check with production fetcher
- [x] 6.3 Print outdated lines to stdout as `category/package vLOCAL -> vREMOTE`
- [x] 6.4 `logWarn` per unconfigured, fetch/parse error, and ahead; exit `0` when spine succeeds
- [x] 6.5 Ensure default log level remains warn so soft warnings are visible

## 7. Verification

- [x] 7.1 Run full hand-rolled test suite (`cabal test`) without live network
- [x] 7.2 Manually smoke-test `outdated` against the real mndz overlay (optional; not required for CI)
- [x] 7.3 Confirm `help` / `--help` lists `outdated`
