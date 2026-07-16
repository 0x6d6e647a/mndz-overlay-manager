## 1. Version parse and compare helpers

- [x] 1.1 Add pure helpers to parse a `go.mod` top-level `go` directive version (ignore comments and `toolchain` for the version source)
- [x] 1.2 Add pure helpers to parse host `go version` output into a comparable version (strip OS/distro suffixes)
- [x] 1.3 Implement dotted numeric comparison (`host >= required`; missing patch = 0)
- [x] 1.4 Unit tests for parse/compare edge cases (`1.26` vs `1.26.0`, `go1.26.4-X:…`, missing go line)

## 2. Host Go gate in vendor construction

- [x] 2.1 Probe host Go version via injectable runner (production: `go version`)
- [x] 2.2 After clone and `go.mod` found, gate: if host strictly older than required, hard-fail with actionable message (both versions; upgrade `dev-lang/go`; no `GOTOOLCHAIN=auto`)
- [x] 2.3 Ensure vendor child env does **not** force `GOTOOLCHAIN=auto` (leave host policy alone aside from existing `GOMODCACHE`)
- [x] 2.4 On `go mod download` failure, optionally enrich stderr when it looks like a toolchain/version mismatch
- [x] 2.5 Unit/integration-style tests with injected ops: older host skips download; equal/newer host proceeds

## 3. Ebuild BDEPEND upsert

- [x] 3.1 Pure function to ensure `>=dev-lang/go-<ver>:=` in ebuild content (insert after inherit or replace existing `dev-lang/go` atom)
- [x] 3.2 Unit tests: missing BDEPEND, outdated atom, unrelated BDEPEND atoms preserved, unparseable ebuild fails safely
- [x] 3.3 Wire BDEPEND rewrite into Go overlay ebuild mutation path using the cloned `go.mod` requirement
- [x] 3.4 Fold “BDEPEND incorrect/missing for required go version” into same-PV “needs content fix” / revision-bump decision so apply does not soft-skip solely on PV match

## 4. Apply wiring and quality gates

- [x] 4.1 Plumb required Go version from vendor/clone path into overlay rewrite (avoid re-cloning solely for BDEPEND)
- [x] 4.2 Confirm hard-fail outcomes surface as package errors and do not abort sibling packages
- [x] 4.3 Run `hk fix` / format and `hk check` (or full project quality pipeline) until green
- [x] 4.4 Manual smoke (operator): attempt crush update with host older than go.mod → clear hard-fail; with sufficient host Go → BDEPEND present on ebuild after apply
