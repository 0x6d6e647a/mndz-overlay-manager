# Proposal

## Why

The Storytold craft ebuilds call `domenu` and `doicon` without inheriting `desktop`, so those calls are skipped and the `.desktop` file and hicolor icons are never installed. The same ebuilds depend on `gnome-base/zenity`, a package that is not in the Gentoo tree. The real package is `gnome-extra/zenity`. [Pull request #3](https://github.com/0x6d6e647a/mndz-overlay/pull/3) fixes the ebuilds. The living specs still require the missing atom, so the next reader would treat the fix as a spec violation.

## What Changes

- Land Petr Komogortsev's thirteen ebuild revision bumps from pull request #3 on `mndz-overlay` `master`. Each ebuild changes `inherit cargo xdg` to `inherit cargo desktop xdg` and `gnome-base/zenity` to `gnome-extra/zenity`.
- Reword those commits to this overlay's one-line subjects (`category/pn: <PVR>`), drop the commit bodies, keep Petr as the author, and GPG-sign them here. Regenerate each package's `metadata/md5-cache` on this machine and amend that cache into the same commit.
- Update `storytold-craft-apps` and `media-gfx-photocraft-seed` so `USE=-portal` depends on `gnome-extra/zenity`, and require these ebuilds to inherit `desktop`.

## Non-goals

- No overlay-manager Haskell. The next Cargo bump copies the donor ebuild. `pycargoebuild --inplace` rewrites `CRATES`, `GIT_CRATES`, and the generated crate-license block, so `inherit` and the zenity atom stay.
- No manager logic that injects `desktop` when an ebuild omits it.
- No `mndz-overlay-assets` release. `SRC_URI` and the crates tarballs do not change.
- No `Manifest` edit. `thin-manifests` leaves `DIST` lines unchanged.
- No `cargo-crates-assets` delta. That spec already requires the Cargo rewrite to preserve conditional dependencies and desktop integration.
- No `README.md`, `CONTRIBUTING.md`, or `AGENTS.md` edit. Operator CLI, config, and the quality pipeline do not change.
- No GitHub "Squash and merge" or "Rebase and merge". Those buttons create new unsigned commits on GitHub.
- No emerge of the thirteen packages in this change. `pkgcheck` covers the missing inherit and the nonexistent dependency.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `storytold-craft-apps`: `USE=-portal` depends on `gnome-extra/zenity`. Each craft app ebuild, including FigCraft, inherits `desktop` so `domenu` and `doicon` exist.
- `media-gfx-photocraft-seed`: the same zenity atom and the same `desktop` inherit for PhotoCraft.

## Impact

- **mndz-overlay:** thirteen revision-bumped ebuilds and their `metadata/md5-cache` entries, as thirteen signed commits on `master`. Pull request #3 is closed after that push. The contributor remains the author of each commit.
- **mndz-overlay-assets:** none.
- **mndz-overlay-manager:** delta specs only. No Haskell. The next `update` of these packages copies the corrected ebuild body.
