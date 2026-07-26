## Why

mndz-overlay is an unstable personal overlay and should follow the same KEYWORDS policy as GURU: packages use **~arch only**; bare stable tokens misrepresent stability (there is no arch-team stabilization process). Runtime-lane planning currently maps plain-lane membership to bare KEYWORDS (`assembleKeywords`: plain → bare, tilde-only → `~`). That was intentional for pure-stable-profile visibility, but it diverges from GURU rule 7.2 and from common overlay practice (e.g. `::science` expects `*/*::science ~${ARCH}`).

Several managed packages already have bare major-arch KEYWORDS (Go, Cargo, and npm). Bin and some Bun packages are already tilde-only.

## What Changes

- **Policy (manager):** For all `DepsAndAssets` ecosystems (Go, Cargo, npm, Bun, and any future lane-planned technique that uses the shared KEYWORDS assembler), planned and written KEYWORDS SHALL use **tilde** arch tokens only (`~amd64`, never bare `amd64`). Plain vs tilde **lanes** still select which package PV and which arches appear; they no longer control bare vs `~` stability marking.
- **Implementation preference:** one shared helper (today: `assembleKeywords` / collapse path) so every ecosystem inherits the rule; no Go-only branch.
- **Overlay:** Revision-bump (`-rN`) **every** non-live ebuild in mndz-overlay that currently has any bare KEYWORDS arch token, so the tree is fully tilde-compliant before/as the manager enforces the policy.
- Specs/tests updated so plain lanes no longer imply bare KEYWORDS on written ebuilds for any ecosystem.

## Non-goals

- Changing Gentoo tree or runtime ceiling discovery (how plain/tilde ceilings are read from `dev-lang/go`, `rust`, `nodejs`, etc. stays the same).
- Seeding new packages or first-time packaging.
- Re-keywording packages already fully `~*` (or `-*` plus `~arch` only).
- Emitting both bare and `~` for the same arch on one ebuild.
- Stabilizing packages or inventing an arch-team process.
- Hard QA gate that scans the whole overlay for bare KEYWORDS outside manager plan/write (optional later).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `runtime-lanes`: Collapse KEYWORDS for **all** ecosystems uses tilde tokens only for every arch with lane membership; plain/tilde lanes affect PV selection and arch set only.
- `go-tree-lanes`: KEYWORDS assembly for planned Go PVs uses tilde tokens only (align with shared rule).
- `go-vendor-assets`: Overlay write KEYWORDS for Go packages match tilde-only policy.
- Ecosystem write paths that pass through planned KEYWORDS (Cargo, npm, Bun via shared assembly) inherit the same rule; no bare from plain lanes.

## Impact

- **mndz-overlay-manager**: KEYWORDS assembly in lane planning and overlay write paths for all `DepsAndAssets`; tests that expect bare `amd64` for plain-lane plans.
- **mndz-overlay**: content/`-rN` revisions on every ebuild with bare KEYWORDS (see design inventory); Manifest/md5-cache as usual.
- **Operator / consumers**: packages are testing-only; pure `ACCEPT_KEYWORDS="amd64"` without `~` will not see them unless accept_keywords is set (e.g. `*/*::mndz ~amd64`), same pattern as GURU/science.
- **Reverses product meaning of** archived change `go-lane-keywords-plain-bare` for token form only; lane planning itself remains.
