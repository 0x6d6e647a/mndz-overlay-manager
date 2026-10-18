# Design

## Context

See proposal.md for why deckcraft 0.8.0, wordcraft 0.8.0, and effectcraft 0.11.1 die in `src_compile`. DesignCraft 0.9.0 already carries the one-line `[patch.*]` rewriter inline in `src_prepare`. `cargo.eclass` writes `[patch]` into `CARGO_HOME/config.toml`; on rust-bin 1.98.1 that table still does not satisfy a git dependency listed under `[patch.*]`. Direct workspace git dependencies stay on that table.

Full-path and reuse Cargo writes both pass the ebuild body through `ensureCargoAssetsSrcUriForHost` in `publishPrepared`. That helper already has the package name and already calls `ensureGitCrateSrcUri`. `metadata/layout.conf` has `masters = gentoo`, and the overlay has no `eclass/` directory yet.

## Goals / Non-Goals

**Goals:**

- One copy of DesignCraft's matcher, read from the overlay at emerge time.
- The four current ebuilds call it, in place, with no `-r1`.
- A later Cargo rewrite of a Storytold GitTag package that declares `GIT_CRATES` leaves that call in place, including when the donor has no `src_prepare`.
- An existing `src_prepare` keeps its other statements. A phase with no `default` fails the package before mutation.

**Non-Goals:**

- See proposal.md. In particular, do not export `src_prepare` from the eclass, do not wrap `cargo_src_compile`, and do not change the matcher.

## Decisions

### Move the matcher into `mndz-cargo.eclass`

Add `eclass/mndz-cargo.eclass` in the overlay. The function `mndz-cargo_rewrite_patch_git_pins` is DesignCraft's bash loop plus its Python, moved unchanged. It reads `GIT_CRATES`, rewrites `${S}/Cargo.toml`, and dies with the messages that function already uses. It does not call `default`. The eclass does not use `EXPORT_FUNCTIONS`, so an ebuild that defines `src_prepare` cannot be shadowed by the inherit.

The four ebuilds inherit `mndz-cargo` immediately after the `cargo` token and call the helper from `src_prepare` after `default`:

- `app-office/deckcraft/deckcraft-0.8.0.ebuild`
- `app-office/wordcraft/wordcraft-0.8.0.ebuild`
- `media-video/effectcraft/effectcraft-0.11.1.ebuild`
- `app-office/designcraft/designcraft-0.9.0.ebuild`

The first three have no `src_prepare` today, so they gain the short phase. DesignCraft's phase keeps `default` and drops the inline Python. No commit id from a pin is written into those phases.

Alternative considered: paste the Python into every ebuild from Haskell. A matcher fix would then wait for the next version bump of each package. Rejected.

Alternative considered: export `src_prepare` and treat a bare inherit as the hook. The manager would miss ebuilds that define their own phase, and an exported phase would replace Soundcraft's libz edit on a later update. Rejected.

### Insert the hook beside the git-crate fetch line

After `ensureGitCrateSrcUri`, a Storytold GitTag rewrite runs `ensureStorytoldPatchPinHook`. The package set is the Cargo GitTag policies whose GitHub owner is `storytold`: photocraft, gridcraft, wordcraft, designcraft, deckcraft, cadcraft, figcraft, vectorcraft, lightcraft, soundcraft, filmcraft, pdfcraft, and effectcraft. `craft-fonts` is Unsupported and is not in the set. Codex is not in the set. A test locks that set to those Hardcoded policies so the two lists cannot drift.

The hook is a no-op unless the ebuild declares `GIT_CRATES`. It then:

- inserts `mndz-cargo` immediately after the `cargo` token on the `inherit` line
- when `src_prepare` is absent, adds a phase that calls `default` and then `mndz-cargo_rewrite_patch_git_pins`
- when `src_prepare` exists, inserts that call on the line after `default` and leaves every other statement
- when the inherit and the call are already in that shape, leaves the ebuild unchanged
- when `GIT_CRATES` is declared and `src_prepare` has no `default`, or the `inherit` line has no `cargo` token, returns an error

`publishPrepared` maps that error to `ApplyHardFail` before ebuild, Manifest, or commit mutation. The function is pure text, same as the other `ensure*` helpers.

Alternative considered: add the hook only when the packed `Cargo.toml` contains a `[patch.*]` git pin. That is a second parser, and a pin it misses ships without the hook. Rejected.

Alternative considered: key the set off the string `storytold` in `HOMEPAGE`. A donor can change that line. The policy owner is the source of truth. Rejected.

### Prove the matcher on the preserved work trees

Replay the helper against the three failed work trees and run `cargo metadata --offline` with that tree's cargo home. Restore each tree's `Cargo.toml` and `Cargo.lock` afterward and check the restore with `cmp`. The trees are:

- `/var/tmp/portage/app-office/deckcraft-0.8.0-2026-10-18T00:02:16-07:00/work/deckcraft-0.8.0`
- `/var/tmp/portage/app-office/wordcraft-0.8.0-2026-10-18T00:02:28-07:00/work/wordcraft-0.8.0`
- `/var/tmp/portage/media-video/effectcraft-0.11.1-2026-10-18T09:15:10-07:00/work/effectcraft-0.11.1`

Deckcraft's `krilla` pin keeps `version = "=0.8.2"`. Wordcraft's `krilla` pin has no `version` key. Effectcraft's `hayro-syntax` pin keeps `version = "=0.7.2"`. Effectcraft's commented `[patch."https://github.com/storytold/filmcraft"]` line stays a comment. `craft-pdf` and Effectcraft's filmcraft git lines stay git dependencies.

The operator re-emerges the three failed atoms. The agent does not run `emerge`.

## Risks / Trade-offs

- [A later tag uses a multiline `[patch.*]` table or `branch` instead of `rev`] → `src_prepare` dies and names the crate. That is the signal to extend the matcher. The moved Python is what makes that die.
- [Soundcraft's next update has a custom `src_prepare`] → the call is inserted after `default` and the libz edit stays. A fixture covers that shape. The current Soundcraft ebuild is not edited in this landing.
- [DesignCraft is already installed] → replacing inline Python with the same matcher does not change the installed files. No `-r1`. Rollback of the ebuild does not require uninstalling 0.9.0.
- [The three failed PVRs never merged] → edit them in place. Rollback is restoring those ebuilds and removing the eclass.
- [`ensureCargoAssetsSrcUriHost` returns `Text` today] → the hard-fail has to surface through `publishPrepared` without writing the ebuild. A `Left` from the hook is that path.
- [The work-tree replay rewrites `Cargo.toml`] → restore both `Cargo.toml` and `Cargo.lock` before finishing, and verify with `cmp`.

## Migration Plan

1. Add the eclass and switch the four ebuilds. Regenerate md5-cache for those four packages only.
2. Replay the helper on the three preserved work trees, then restore them.
3. Add the manager hook and its tests. `just check` is the manager gate.
4. The operator re-emerges `=app-office/deckcraft-0.8.0`, `=app-office/wordcraft-0.8.0`, and `=media-video/effectcraft-0.11.1`.
5. Do not commit either repository unless the operator asks. Overlay commits stay signed by the operator.
