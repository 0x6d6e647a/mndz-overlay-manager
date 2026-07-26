## Why

BadgerDB’s CLI is not packaged in Gentoo or the mndz overlay. A hand-seeded `dev-db/badger` ebuild at v4.9.4 (with published Go vendor assets) is the prerequisite for automated updates and for proving the jemalloc / completion / test USE shape before mndz-overlay-manager is taught about the package.

## What Changes

- Add `dev-db/badger` version `4.9.4` to **mndz-overlay** (ebuild, `metadata.xml`, Manifest).
- Publish `badger-4.9.4-vendor.tar.xz` (and checksum sidecars) to **mndz-overlay-assets** under release tag `badger-4.9.4`.
- Ebuild inherits `go-module` and `shell-completion`; builds the CLI from `./badger`.
- `IUSE="bash-completion fish-completion jemalloc test zsh-completion"` with `RESTRICT="!test? ( test )"`.
- `USE=jemalloc` builds a private jemalloc with `--with-jemalloc-prefix=je_` from a fixed upstream jemalloc tarball in `SRC_URI` and static-links it (no runtime dep on `dev-libs/jemalloc::gentoo`).
- Shell completions generated via `badger --dir /var/empty completion …` (upstream requires `--dir` even for completion).
- KEYWORDS follow the current Crush-style go-lane arch set (bare/tilde mix); tilde-only overlay policy is deferred to `overlay-tilde-keywords`.
- Operator acceptance: emerge the package and run `badger --help`.

## Non-goals

- No mndz-overlay-manager code or hardcoded policy (see `support-dev-db-badger`).
- No update to a version newer than 4.9.4 (leave headroom for Phase 2 smoke).
- No KEYWORDS tilde-only enforcement across the overlay.
- No ralph-tui or other package fixes.
- No library-only packaging of BadgerDB (CLI package only).

## Capabilities

### New Capabilities

- `dev-db-badger-seed`: Requirements for the manually seeded `dev-db/badger` ebuild, vendor assets layout, jemalloc private build, USE flags, and acceptance smoke.

### Modified Capabilities

- (none — this change does not alter manager product requirements)

## Impact

- **mndz-overlay**: new package tree `dev-db/badger/`.
- **mndz-overlay-assets**: new release + sidecars under `dev-db/badger/`.
- **mndz-overlay-manager**: planning artifacts only; no implementation in this change.
- **Operator**: manual emerge + CLI smoke after publish.
- **Downstream**: enables `support-dev-db-badger` (manager update path).
