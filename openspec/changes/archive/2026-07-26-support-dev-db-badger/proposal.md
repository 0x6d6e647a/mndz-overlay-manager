## Why

After `dev-db/badger` is seeded at 4.9.4, mndz-overlay-manager still treats the package as unsupported (no hardcoded policy). Registering it as `DepsAndAssets` / Go enables automated version bumps; apply must also preserve the seed ebuild’s companion jemalloc `SRC_URI` so jemalloc support is not stripped on update.

## What Changes

- Add hardcoded policy for `dev-db/badger`: GitHub `dgraph-io/badger`, tag prefix `v`, technique `DepsAndAssets` with ecosystem `Go` and go.mod at repository root.
- Require Go overlay apply to **preserve** non-assets `SRC_URI` entries (including `USE? ( … )` blocks such as the fixed jemalloc tarball) when parameterizing assets URLs, rewriting BDEPEND/KEYWORDS, and writing a new PV.
- Spec and tests covering policy resolution and jemalloc (or equivalent companion) `SRC_URI` preservation.
- Operator acceptance after implement: run manager update for `dev-db/badger` (expected bump past 4.9.4), emerge the new version, run `badger --help`.

## Non-goals

- Creating the initial ebuild or first vendor tarball (belongs to `seed-dev-db-badger`).
- Changing KEYWORDS to tilde-only (belongs to `overlay-tilde-keywords`).
- Bumping or managing jemalloc upstream versions automatically.
- Publishing jemalloc into mndz-overlay-assets.
- Altering jemalloc private-build logic inside the ebuild (`src_compile` remains template-owned).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `go-vendor-assets`: Add `dev-db/badger` to hardcoded Go packages; require preservation of non-assets companion `SRC_URI` (e.g. jemalloc) across Go apply rewrites.
- `update-apply`: Extend the hardcoded policy inventory requirement so `dev-db/badger` is listed among Go `DepsAndAssets` packages.

## Impact

- **mndz-overlay-manager**: `Update.Hardcoded`, Go apply/ebuild edit paths, unit tests, delta specs.
- **mndz-overlay / assets**: mutated only when the operator runs `update` for badger after this lands.
- **Depends on**: completed `seed-dev-db-badger` (template ebuild + assets pattern present).
