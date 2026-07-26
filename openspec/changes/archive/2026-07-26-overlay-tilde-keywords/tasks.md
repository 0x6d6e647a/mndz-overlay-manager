## 1. Manager KEYWORDS assembly (all DepsAndAssets)

- [x] 1.1 Change shared KEYWORDS assembly (`assembleKeywords` / collapse path) so every included arch is emitted as `~arch` (never bare), while plain/tilde lanes still select PVs and arch membership
- [x] 1.2 Confirm Cargo, npm, Bun, and Go all consume that helper (or equivalent) so no ecosystem still emits bare from plain lanes
- [x] 1.3 Update unit/integration tests that expect bare `amd64`/`arm64` for plain-lane plans (any ecosystem) to expect tilde tokens

## 2. Specs

- [x] 2.1 Confirm living/delta alignment for `runtime-lanes` (all ecosystems tilde-only), `go-tree-lanes`, and `go-vendor-assets`
- [x] 2.2 Spot-check cargo/npm/bun living specs for contradictory “plain → bare” language; rely on `runtime-lanes` as SoT if no dedicated KEYWORDS requirement

## 3. Overlay revisions (all bare KEYWORDS ebuilds)

### Go

- [x] 3.1 Revision-bump `dev-db/dolt` with all-tilde KEYWORDS (preserve arch set)
- [x] 3.2 Revision-bump `dev-util/beads` with all-tilde KEYWORDS
- [x] 3.3 Revision-bump `dev-util/crush` with all-tilde KEYWORDS
- [x] 3.4 Revision-bump `dev-db/badger` with all-tilde KEYWORDS

### Cargo

- [x] 3.5 Revision-bump `dev-util/mise` with all-tilde KEYWORDS
- [x] 3.6 Revision-bump `dev-util/hk` with all-tilde KEYWORDS
- [x] 3.7 Revision-bump `dev-util/usage` with all-tilde KEYWORDS

### npm

- [x] 3.8 Revision-bump `dev-util/openspec` with all-tilde KEYWORDS

### Finish

- [x] 3.9 Manifest / md5-cache / overlay commits as required for each revised package
- [x] 3.10 Re-scan mndz-overlay non-live ebuilds for any remaining bare arch KEYWORDS tokens (excluding intentional `-*` only)

## 4. Verification

- [x] 4.1 Run `hk check` in mndz-overlay-manager
- [x] 4.2 Spot-check KEYWORDS on all revised ebuilds: every arch token is tilde-prefixed (or package is `-*` + `~` only)
- [x] 4.3 Confirm already-compliant packages (`opencode`, `ralph-tui`, bins) were not unnecessarily revbumped
