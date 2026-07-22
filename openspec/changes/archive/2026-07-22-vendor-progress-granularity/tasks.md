## 1. Vendor progress hooks

- [x] 1.1 Add a `VendorProgress` (or equivalent) callback bag with start/done hooks for clone, go mod download, and compress; provide a no-op default for tests and call sites that ignore UI
- [x] 1.2 Thread progress into `buildVendorTarball` and fire hooks at the existing clone / download / tar seams (host Go gate remains under the download phase without its own step)
- [x] 1.3 Update production and test call sites of `buildVendorTarball` to pass progress (no-op where indicators are not used)

## 2. Apply step accounting and path wiring

- [x] 2.1 Replace `materializePlan`’s per-PV `* 3` budget with full-path upper bound (`× 7`) plus revise-after-probe helper for full (7) vs reuse (3) remaining work
- [x] 2.2 In `goPublishAndOverlay` (or equivalent), set non-advancing status during release-asset probe (e.g. `probing release asset`) before choosing path
- [x] 2.3 Wire `fullPublishAndOverlay` to full-path steps: vendor hooks → `cloning upstream` / `go mod download` / `compressing tarball`; then `committing assets` (hash + sidecars + commit), `pushing assets`, `uploading release asset` (create release + upload), `regenerating manifest`
- [x] 2.4 Wire `reuseReleaseAsset` so its three phases remain first-class steps under the new budget math and never emit full-path vendor/publish names
- [x] 2.5 On hard-fail mid-path, do not advance `mhStep` for incomplete work; leave the active step name for the failure row

## 3. Tests

- [x] 3.1 Unit-test vendor progress event order for a successful `buildVendorTarball` (recording progress + mocked `VendorOps`)
- [x] 3.2 Unit-test or integration-style assert of full-path apply progress event sequence (clone → download → compress → commit → push → upload → manifest)
- [x] 3.3 Assert reuse-path progress sequence and absence of vendoring/publishing/full-path names
- [x] 3.4 Assert step-total revise behavior for mixed full/reuse multi-PV budgets (or single-PV full vs reuse totals)

## 4. Quality gate

- [x] 4.1 Run `hk check` (or full CONTRIBUTING pipeline) and fix any format/lint/stan/weeder/test failures
