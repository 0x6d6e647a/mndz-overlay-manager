## Why

mndz-overlay packages are inconsistent about Portage’s test gate. The standard pattern (Gentoo `dev-go/delve`, seeded `dev-db/badger`) is:

```bash
IUSE="… test"
RESTRICT="!test? ( test )"
# src_test runs the real suite; RESTRICT is the primary gate
```

Today only **badger** has that full pair. **ralph-tui** declares `IUSE="test"` but lacks the RESTRICT gate (manual `if use test` only). Go packages (**dolt**, **beads**, **crush**) and Cargo packages (**hk**, **mise**, **usage**) run tests whenever `FEATURES=test` with no `USE=test` opt-in. **opencode** and **openspec** have no `src_test` at all despite being from-source packages with upstream suites.

Operators who set global `FEATURES=test` need a uniform, opt-in `USE=test` story across the overlay (excluding prebuilts).

## What Changes

Bring **all non-prebuilt** mndz-overlay packages onto the badger/delve convention in one change:

| Package | Action |
|---------|--------|
| `dev-util/ralph-tui` | Add missing `RESTRICT="!test? ( test )"`; keep/fix `src_test` (`bun test`); drop redundant `if use test` if desired |
| `dev-db/dolt`, `dev-util/beads`, `dev-util/crush` | Add `IUSE="test"` + `RESTRICT="!test? ( test )"`; keep existing `ego test ./...` |
| `dev-util/hk`, `dev-util/mise`, `dev-util/usage` | Add `IUSE` including `test` + `RESTRICT="!test? ( test )"` so inherited `cargo_src_test` is gated; keep eclass default (or thin wrapper) |
| `dev-util/opencode` | Add `IUSE` including `test` + merge RESTRICT with existing `strip`; add `src_test` (Bun suite offline against deps tarball) |
| `dev-util/openspec` | Add `IUSE` including `test` + RESTRICT; add `src_test` (npm/offline-friendly suite against deps tarball) |
| `dev-db/badger` | Already compliant — no ebuild change |

**Revision policy:** every non-version content edit to an ebuild **must** ship as a new `-rN` revision (git-mv `PV` → `PV-rN` or `PV-rN` → `PV-r(N+1)`), never an in-place overwrite of the live ebuild filename. Manifest / md5-cache updated accordingly.

## Non-goals

- Prebuilt packages (`dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`) — no source test suite; optional smoke tests are a separate change.
- Changing package build systems, deps/vendor/crates tarball pipelines, or mndz-overlay-manager update policy (except fixture updates if any assert old ebuild shapes).
- Making `USE=test` the default for emerge (still opt-in; `FEATURES=test` alone is insufficient without `USE=test`).
- Guaranteeing every upstream suite is green on every arch under sandbox — flaky/network tests may use skips / `CARGO_SKIP_TESTS` / scoped commands, documented in the ebuild.

## Capabilities

### New Capabilities

- `overlay-test-use`: Portage `IUSE=test` + `RESTRICT="!test? ( test )"` convention, `src_test` expectations, and mandatory `-rN` for non-version ebuild content edits in mndz-overlay.

### Modified Capabilities

- (none — no mndz-overlay-manager product requirement change)

## Impact

- **mndz-overlay**: revision-bumped ebuilds for ralph-tui, dolt, beads, crush, hk, mise, usage, opencode, openspec; Manifest + md5-cache; commits per overlay style.
- **mndz-overlay-manager**: planning artifacts only; update fixtures only if they embed old ebuild shapes.
- **Operators**: with `USE=-test` (default) and `FEATURES=test`, test phases are restricted for gated packages; with `USE=test` + `FEATURES=test`, suites run.
