# Design

## Context

See proposal.md for why FilmCraft 0.18.0 dies offline. `stripWindowsOnlyGitCrates` drops a lock git package when `windowsOnlyDepNames` finds only windows-only or wasm-only edges. That list is correct for `dev-util/codex`, whose `src_prepare` stubs `appcontainer_common` and `learning_mode_windows` instead of fetching `microsoft/mxc`. Cargo resolves `[target]` dependencies for the workspace on every platform, so the same drop removes a crate the native build still has to load.

A draft of the code, tests, and FilmCraft ebuild edits is in git stash `grok-off-leash` in this repo and in `mndz-overlay`. Implementation may start from those stashes. The stash also rewrites the two living specs. Leave `openspec/specs/` unchanged until this change is synced or archived.

## Goals / Non-Goals

**Goals:**

- Keep the omit for package name `codex` and stop applying it to every other Cargo GitTag package.
- Make `media-video/filmcraft-0.18.0` fetch `craft-web-host` so a new emerge can resolve the workspace offline.
- Leave `windowsOnlyDepNames` and the tag-floor `cfg` walk unchanged.

**Non-Goals:**

- Rewriting every already-generated ebuild. Other packages pick up a kept crate on their next `update`.
- An eclass change. Once `craft-web-host` is a `GIT_CRATES` key, prepare's missing-checkout check does not apply to it.
- A USE flag, a browser-build package, or a Storytold stub crate.

## Decisions

1. **Gate the drop on `pn == "codex"`.** `buildCargoCratesTarball` already receives the ebuild package name. Pass it into `stripWindowsOnlyGitCrates`. For `codex`, drop the `windowsOnlyDepNames` set. For every other name, drop nothing.

   Alternative: a global denylist of `mxc`, `appcontainer_common`, and `learning_mode_windows`. Rejected. Codex omits every windows-only or wasm-only git crate, not three names, and a Storytold crate with one of those names would be fetched.

2. **Fix FilmCraft 0.18.0 in the overlay now.** Add

   `craft-web-host` → `https://github.com/storytold/craft-libs` at `2e2312ddaf21bc3d85cd3395d0955c7d239306f6`, directory `craft-libs-%commit%/crates/web-host`.

   Copy the existing `craft-libs-2e2312ddaf21bc3d85cd3395d0955c7d239306f6.gh.tar.gz` Manifest line from a sibling ebuild. Regenerate `metadata/md5-cache/media-video/filmcraft-0.18.0` with `egencache`. The distfile is already in `/var/cache/distfiles`.

   Alternative: wait for the next manager `update` to rewrite the ebuild. Rejected. The installed ebuild is what the emerge reads, and this PV is already the one that failed.

3. **Tests keep both modes.** The existing GitCrates fixture stays the Codex case (`pn` `codex` drops `mxc` and a wasm-only crate). A second call with a non-Codex package name keeps those crates, including one named from a wasm target table and also from `[dev-dependencies]`. A dev-only git crate stays in both modes, because dev-dependencies are not edges and the strip never selected it.

## Risks / Trade-offs

- [The next `update` of a non-Codex package fetches a windows-only or wasm-only git repo that used to be omitted] → That fetch is the point. Codex stays on the old rule. This change does not rewrite ebuilds that are not being updated.
- [`pn == "codex"` misses a second package that must keep stubbing] → Only `dev-util/codex` has that stub contract. A new package with the same need gets its own rule rather than sharing the string.
- [The operator resumes the failed FilmCraft work directory] → Prepare already rewrote `[patch.*]` lines to a Portage path that has been removed. The emerge has to start a new work directory.
- [Popping `grok-off-leash` writes the living specs early] → Pop the code, tests, and overlay files. Leave the two spec hunks until archive.

## Migration Plan

1. Land the manager strip and tests. `just check` is the gate.
2. Land the FilmCraft ebuild, Manifest line, and regenerated md5-cache in `mndz-overlay`.
3. The operator re-emerges `media-video/filmcraft` in a new work directory.
4. Sync the two deltas into `openspec/specs/` at archive.

Rollback of the manager rule restores the omit on the next `update`. The FilmCraft `GIT_CRATES` line has to stay, or that update deletes it and the emerge fails again.

## Open Questions

None.
