## Context

`GoVendorAndAssets` clones upstream, runs `go mod download` with `GOMODCACHE` forced into a local `go-mod/` tree, tars that tree, publishes assets, then rewrites the overlay ebuild (`SRC_URI` parameterization, rename/revision) and runs `ebuild … manifest`.

Observed failure (F2): crush (and any package whose `go.mod` advances) fails when host Go is older than the `go` directive and the environment uses `GOTOOLCHAIN=local` (common on Gentoo). Example: host `go1.26.4`, package requires `go 1.26.5`. Preflight only checks that `go` is on `PATH`. Ebuilds inherit `go-module.eclass` (`BDEPEND=">=dev-lang/go-1.24.11:="`) and do not declare the package’s real floor, so emerge can start and fail late.

Product decision from explore: **do not** enable `GOTOOLCHAIN=auto` for vendor construction. Maintainer and Portage user should share distro `dev-lang/go`. Prefer a clear hard-fail plus ebuild `BDEPEND` from `go.mod`.

## Goals / Non-Goals

**Goals:**

- Detect host Go older than the cloned package’s `go.mod` `go` line and hard-fail with an actionable message before or instead of opaque `go mod download` noise
- Upsert overlay ebuild `BDEPEND` to `>=dev-lang/go-<required>:=` from that same `go` line so emerge dependency solving matches upstream
- Keep vendor child environment free of toolchain auto-download overrides (respect host `GOTOOLCHAIN`, typically `local`)
- Unit-test parse/compare and BDEPEND text helpers without live network Go toolchain downloads

**Non-Goals:**

- `GOTOOLCHAIN=auto` or downloading `golang.org/toolchain` modules during vendor
- F1 half-apply/orphan resume; F3 `--force` dirty
- Using the `toolchain` directive as BDEPEND (use the `go` language line only)
- Changing Gentoo `go-module.eclass` or guaranteeing a given Go version exists in the tree
- Static global “minimum Go” preflight for all packages (version is per-clone)
- Soft-skip when Go is too old (must hard-fail the package)

## Decisions

### 1. Host Go gate, not auto toolchain

**Choice:** Compare host `go version` to `go.mod`’s `go` directive; if host is strictly older, hard-fail the package with a message that names both versions and points at upgrading `dev-lang/go` (including that `~amd64` / waiting for tree may be required). Do **not** set `GOTOOLCHAIN=auto` on the vendor child.

**Alternatives considered:**

| Option | Why rejected |
|--------|----------------|
| `GOTOOLCHAIN=auto` for vendor only | Can place toolchains under forced `GOMODCACHE=go-mod` and bloat/publish non-deps; diverges from Portage’s distro Go |
| Document min Go only | Still fails opaquely; min moves with upstream |
| Soft-warn and continue | Cannot produce a correct vendor apply |

**Rationale:** Packaging purity and honest blockage when the tree lags (e.g. go 1.26.4 in tree while crush 0.83+ needs 1.26.5).

### 2. When to check

**Choice:** After successful temp clone and locating `go.mod` (existing go.mod presence check), parse requirement and host version **before** `go mod download`. If download still fails with toolchain/version-looking stderr, append the same style of hint when not already gated.

**Rationale:** Early, cheap, clear. Avoids multi-minute fail on large module graphs when the only issue is host Go.

### 3. Version parsing rules

**Choice:**

- From `go.mod`: first top-level line matching `^go <version>` (ignore `//` comments and lines inside `require (` blocks by simple line scan: only lines whose first token is `go` and second is a version-like token). Support `1.26`, `1.26.4` (two or three numeric components).
- From host: run `go version` (or injectable runner); parse `go1.26.4` / `go1.26.4-X:…` style from the output (strip OS/suffix after version core).
- Compare as dotted numeric tuples; missing patch treated as `0` for ordering (`1.26` ≡ `1.26.0`). Host satisfies requirement iff host ≥ required.
- Missing/unparseable `go` line: skip the version gate (fall through to `go mod download`); still hard-fail on download failure. Unparseable host version: hard-fail with “could not parse go version”.

**Rationale:** Matches how Go and Gentoo ebuilds express floors without full go.mod AST.

### 4. BDEPEND rewrite from `go` line only

**Choice:** On the overlay ebuild content path (alongside existing assets `SRC_URI` parameterization), ensure the ebuild contains:

```ebuild
BDEPEND=">=dev-lang/go-1.26.5:="
```

(using the exact version string from `go.mod`, e.g. `1.26` or `1.26.5`). Prefer:

- If a `BDEPEND=...` or `BDEPEND+="..."` already contains a `dev-lang/go` atom, replace that atom with the required `>=dev-lang/go-<ver>:=` (preserve surrounding BDEPEND form when practical).
- If no `dev-lang/go` atom exists, insert after `inherit go-module` (or after the last `inherit` line if more specific placement is awkward) a line `BDEPEND=">=dev-lang/go-<ver>:="`.

Do **not** use the `toolchain` directive for BDEPEND. Do **not** strip unrelated BDEPEND atoms.

**Rationale:** Tree packages (gitea, etc.) override eclass floor this way; Portage AND with eclass `>=1.24.11` yields the higher floor when both are present. Explicit package atom is clearer for readers.

**Same-PV content change:** If only BDEPEND (or BDEPEND + SRC_URI) changes at the same PV, existing revision-bump logic for content fixes should treat BDEPEND-needed as “needs overlay mutation” the same way non-parameterized SRC_URI does—i.e. if local is already at remote PV but BDEPEND is missing/wrong, plan a revision bump and rewrite. Design implementers: fold “BDEPEND matches required go version” into the “needs content fix” check used for Go packages.

### 5. Error message shape (operator)

Hard-fail text SHOULD include:

1. Package key / context if available from apply layer
2. Host version and required version
3. That the tool does not auto-download Go toolchains
4. Action: install/upgrade `dev-lang/go` to at least the required version (keyword unmask / wait for tree as operator knowledge)

### 6. Implementation placement

| Concern | Module |
|---------|--------|
| Parse go.mod `go` line; parse `go version`; compare | Pure helpers (e.g. `Update.Go.Version` or under `Update.Go.Vendor`) |
| Run host `go version`; gate before download | `Update.Go.Vendor` production path + injectable ops for tests |
| BDEPEND upsert | `Update.EbuildEdit` pure function |
| Wire required version into ebuild rewrite / “needs fix” | `Update.Apply` Go path |

`VendorOps` may gain an optional host-version step or fold check into `voGoModDownload` / `buildVendorTarball` so tests inject without shelling out.

### 7. Tests

- Pure: parse go.mod samples (with comments, `toolchain` line present but ignored for BDEPEND source); compare versions; BDEPEND insert/replace
- Vendor ops: when host older than required, `buildVendorTarball` fails without calling download (mock)
- No CI dependency on fetching real toolchains or live crush clones

## Risks / Trade-offs

- [Tree lags upstream Go] → Hard-fail until Gentoo has a new enough `dev-lang/go`; intentional. Message must not suggest `GOTOOLCHAIN=auto` as the supported path.
- [Operator expects auto to “just work”] → Documented non-goal; packaging consistency over convenience.
- [go.mod uses only major.minor] → BDEPEND `>=dev-lang/go-1.26:=` still valid in Portage.
- [Fragile ebuild BDEPEND editing] → Prefer pure string helpers with unit tests; fail closed if ebuild structure is unrecognizable (hard-fail package with edit error rather than write broken ebuild).
- [go-module.eclass already sets BDEPEND] → Package-level atom still valuable for higher floor and readability; duplicate lower floor is OK under Portage AND.
- [Race: go advances between outdated check and apply] → Unchanged; gate runs on the cloned tag for the apply target.

## Migration Plan

1. Ship behind existing `update` for `GoVendorAndAssets` packages only.
2. Operators with sufficient host Go see BDEPEND lines appear on next successful apply.
3. Operators with too-old Go get explicit hard-fail until they upgrade Go.
4. Rollback: revert the change; ebuilds that already received BDEPEND remain correct and harmless.

## Open Questions

None blocking implementation. Optional later: config flag to allow `GOTOOLCHAIN=auto` (explicitly rejected for v1).
