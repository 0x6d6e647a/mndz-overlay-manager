## Why

Go vendor construction fails when an upstream `go.mod` requires a newer Go than the host toolchain (for example crush needing 1.26.5 while the operator has 1.26.4 and `GOTOOLCHAIN=local`). Today the failure is a raw `go mod download` error with no clear upgrade guidance, and overlay ebuilds only inherit `go-module.eclass`’s floor (`>=dev-lang/go-1.24.11`), so emerge users can pass dependency resolution and only fail mid-compile. Follow-up F2 from `go-vendor-assets-update` should fix operator diagnostics and encode the real Go floor in the ebuild.

## What Changes

- After the temp clone for `GoVendorAndAssets`, parse the package `go.mod` language version (`go X.Y` / `go X.Y.Z`) and compare it to the host `go version`
- When the host Go is older than required, hard-fail that package with an actionable message (host version, required version, upgrade `dev-lang/go` / keywords; no silent continue)
- When `go mod download` still fails for other reasons, keep hard-fail; if stderr indicates a toolchain/version mismatch, enrich the error the same way when possible
- On successful overlay ebuild rewrite for Go packages, ensure a `BDEPEND` atom `>=dev-lang/go-<version>:=` matching the `go.mod` `go` directive (upsert; do not rely on eclass floor alone)
- **Do not** set `GOTOOLCHAIN=auto` for vendor construction; use the host distro Go only so maintainer and emerge share one compiler story
- **Non-goals**: half-apply/orphan resume (F1), `--force` dirty paths (F3), downloading Go toolchains, parsing `toolchain` directive as BDEPEND, changing `go-module.eclass` itself

## Capabilities

### New Capabilities

- None (behavior extends existing Go vendor apply)

### Modified Capabilities

- `go-vendor-assets`: Host Go vs `go.mod` version gate with clear hard-fail; rewrite Go ebuilds to declare `BDEPEND` from the `go.mod` `go` line after assets publish path proceeds to overlay mutation
- `update-command`: Document that Go version mismatch is a per-package hard failure (not a spine preflight), with operator-facing error content expectations when applicable

## Impact

- **Code**: `Update.Go.Vendor` (version check around/before `go mod download`); ebuild edit helpers for BDEPEND upsert; `Update.Apply` wiring on the Go overlay path; unit tests for version parse/compare and BDEPEND rewrite
- **Operator**: Must install a new enough Gentoo `dev-lang/go` (possibly `~amd64` or wait for tree) when upstream advances; tool will state that clearly instead of papering over with toolchain auto-download
- **Overlay ebuilds**: Go packages gain explicit `>=dev-lang/go-…:=` so emerge dependency solving matches upstream need
- **External**: Still requires `go` on PATH for Go updates; no new tools
- **Tests**: Pure helpers for `go.mod` / `go version` parsing and BDEPEND text edits; no live toolchain download in CI
