## 1. Policy

- [x] 1.1 Add `dev-db/badger` to `hardcodedPolicies`: GitHub `dgraph-io`/`badger` tag prefix `v`, `DepsAndAssets (Go Nothing)`
- [x] 1.2 Update policy/inventory tests that enumerate Go packages or hardcoded keys

## 2. Companion SRC_URI preservation

- [x] 2.1 Audit Go ebuild rewrite path (`parameterizeAssetsSrcUri` / overlay write) for multi-line SRC_URI with USE-conditionals
- [x] 2.2 Add unit test: frozen vendor assets URL + `jemalloc? ( jemalloc-5.3.x tarball )` companion survives parameterization with vendor URL using `${PV}`
- [x] 2.3 Fix any rewrite path that drops or rewrites non-assets companions

## 3. Specs and quality

- [x] 3.1 Ensure delta specs stay aligned with implementation (`go-vendor-assets`, `update-apply`)
- [x] 3.2 Run `hk check` and fix failures

## 4. Operator smoke

- [x] 4.1 Run manager update for `dev-db/badger` (expect PV newer than 4.9.4 when upstream allows)
  - Operator: updated `4.9.4` → `4.9.5` (overlay commits + assets).
- [x] 4.2 Confirm rewritten ebuild still contains jemalloc companion SRC_URI and USE flags from template
  - Preserved: `JEMALLOC_PV`, `jemalloc? ( … )` SRC_URI, `IUSE=… jemalloc …`, private-build `src_compile`.
- [x] 4.3 Emerge the new version and run `badger --help`
  - Operator: emerge of `dev-db/badger-4.9.5` succeeded; `badger --help` passed.
- [x] 4.4 Report smoke results
  - Smoke OK. Note: ebuild has optional `jemalloc` (no `+` default); system USE may enable it.

