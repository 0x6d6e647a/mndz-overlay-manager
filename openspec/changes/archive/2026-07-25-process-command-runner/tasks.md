## 1. Process seam

- [x] 1.1 Add internal `Update.Process` (or equivalent) with `ProcessRequest` (shell vs exec), `ProcessResult`, and `CommandRunner`
- [x] 1.2 Implement `productionCommandRunner` mapping to existing process invocation style
- [x] 1.3 Wire cabal: prefer `other-modules`; avoid casual `exposed-modules` growth; keep weeder roots entrypoint-oriented

## 2. Ecosystem production adapters

- [x] 2.1 Route npm production process helpers through CommandRunner; expose `mkNpmCacheOps` (or equivalent) for tests
- [x] 2.2 Route bun production process helpers through CommandRunner + `mkBunCacheOps`
- [x] 2.3 Route Go vendor production process helpers through CommandRunner + `mkVendorOps`
- [x] 2.4 Route cargo production process helpers through CommandRunner + `mkCargoOps`

## 3. Simple runners

- [x] 3.1 Route `productionEbuildRunner` through CommandRunner (shell mode)
- [x] 3.2 Route `productionEgencacheRunner` through CommandRunner
- [x] 3.3 Route production portageq runner through CommandRunner

## 4. Unit tests

- [x] 4.1 Unit: npm production/mk path success + failure with scripted runner
- [x] 4.2 Unit: bun production/mk path success + failure with scripted runner
- [x] 4.3 Unit: vendor production/mk path success + failure with scripted runner
- [x] 4.4 Unit: cargo production/mk path success + failure with scripted runner
- [x] 4.5 Unit: ebuild / egencache / portageq production runners with scripted success + failure

## 5. Quality gate

- [x] 5.1 `./scripts/coverage` green (floor-free)
- [x] 5.2 `hk check` green; fix format/lint/analysis/weeder
- [x] 5.3 Confirm registry HTTP bodies remain owned by `registry-http-fakes` (no double-scope creep)
