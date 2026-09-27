# Proposal

## Why

Gas Town (`gastownhall/gastown`) is the workspace manager that drives the Beads and Dolt packages already in the mndz overlay, and nothing in the overlay or the manager follows its releases. A useful install needs a Beads CLI older than the overlay tip, plus a Dolt version at or above a floor that moves with each Gas Town tag, so those constraints have to be seeded and then maintained on `update`.

## What Changes

- Seed `dev-util/gastown` at upstream `1.1.0` (one release behind `1.2.0`, which is itself behind tip `1.2.1`), with a Go vendor tarball, `CGO_ENABLED=0`, shell-completion and `+tmux` USE flags, and `IUSE=test`.
- Seed a second `dev-util/beads` ebuild at `1.0.4` beside the existing `1.3.0` tip. Same `SLOT="0"`. Gas Town `RDEPEND`s on `~dev-util/beads-1.0.4`. A system installs one `bd`; emerging Gas Town selects `1.0.4`.
- Teach `update` to rewrite Gas Town's Dolt atom from `MinDoltVersion` in that tag (`>=dev-db/dolt-1.82.4` at `1.1.0`, `>=dev-db/dolt-2.0.7` at `1.2.1`). Existing atom closure hard-fails the Gas Town apply when no retained Dolt ebuild satisfies the rewritten floor, and waits when a selected Dolt update would.
- Teach `update` to parse Gas Town's Beads version gate and accept only two shapes: a floor (`MinBeadsVersion` only) or an equal min/max ceiling. Any other shape hard-fails the apply before overlay mutation. The parser records the window and prints an operator line only when that window changes. It does not replace `~dev-util/beads-1.0.4` with the looser `>=0.57.0` floor declared by `1.1.0` and `1.2.1`.
- Add `dev-util/gastown` to the hardcoded policy map as `DepsAndAssets` Go (repository root, GitHub `gastownhall/gastown`, tag prefix `v`) so `outdated` reports `1.1.0 -> 1.2.1` and `update` publishes the `1.2.1` vendor tarball and preserves the ebuild body.
- **BREAKING** for a machine that has `dev-util/beads-1.3.0` installed: emerging Gas Town replaces that `bd` with `1.0.4`.

## Capabilities

### New Capabilities

- `dev-util-gastown-seed`: Overlay truth for `dev-util/gastown` `1.1.0` (build, USE, vendor URL, operator Beads pin, Dolt floor, smoke) and for the kept `dev-util/beads-1.0.4` provider ebuild.
- `gastown-dep-gates`: Manager behavior that rewrites the Dolt floor, parses the Beads gate, hard-fails on an unrecognized gate shape or a floor above the operator pin, and notices a changed version window without loosening the pin.

### Modified Capabilities

- `update-apply`: The canonical policy map gains `dev-util/gastown` as `DepsAndAssets` Go with GitHub source `gastownhall/gastown` and tag prefix `v`.
- `overlay-test-use`: `dev-util/gastown` joins the Go packages that declare `test`, `RESTRICT="!test? ( test )"`, and a Go `src_test`.

## Impact

- Overlay checkout: new `dev-util/gastown` and `dev-util/beads/beads-1.0.4.ebuild`, plus Manifest, metadata, and md5-cache. Assets releases `gastown-1.1.0` and `beads-1.0.4` (vendor tarballs). The later `update` adds `gastown-1.2.1` and prunes the `1.1.0` ebuild.
- Manager: `Update.Hardcoded` policy entry, a Gas Town dependency-gate step on apply, policy tests, and delta specs. No new CLI flag and no PV argument.
- Host effect of the install smoke: `bd` moves from `1.3.0` to `1.0.4` while Gas Town is installed. Dolt `2.3.5` already satisfies both floors.

## Non-goals

- Packaging Gas Town `1.2.0`, proxy binaries, town plugins, or an `icu` USE flag.
- A private `bd` under `/usr/libexec`, a second Beads slot, or dropping the Beads `1.3.0` tip.
- Rewriting `~dev-util/beads-1.0.4` from `MinBeadsVersion`, or deleting that pin automatically when the parsed window changes.
- Detecting that a newer `bd` has started succeeding at `bd init`. That failure is inside Beads, not in Gas Town's version gate.
- Running `gt daemon`, `gt up`, or a Mayor session as acceptance. Smoke is `gt version`, shell completion, and `gt install` of a throwaway town with the pinned `bd` and system Dolt.
