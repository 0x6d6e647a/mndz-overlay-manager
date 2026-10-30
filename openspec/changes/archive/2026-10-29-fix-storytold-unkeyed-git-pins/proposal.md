# Proposal

## Why

On 2026-10-29, twelve Storytold craft apps failed `src_prepare` while emerging the same egui pin (`6d518fc799681571963842f95b55a6b68431b15a`). Each `[patch.crates-io]` line names a crate from that git archive, and `mndz-cargo_rewrite_patch_git_pins` dies when that crate is not a `GIT_CRATES` key. The archive is already unpacked. The published ebuilds cannot be merged until prepare can resolve those pins from the checkout on disk.

## What Changes

- `src_prepare` rewrites a one-line `[patch.*]` git pin onto a crate directory inside a checkout already fetched for that `rev`, including when `GIT_CRATES` has no key for that crate name. `version` and `features` stay. The workspace git line is left as a git dependency.
- `src_prepare` dies before `src_compile` when that pin cannot be parsed, when the chosen directory has no `Cargo.toml`, or when no checkout already fetched for that `rev` contains the crate. A missing `GIT_CRATES` key alone is no longer fatal.
- `src_prepare` registers a direct git dependency that is missing from `GIT_CRATES` when a checkout already fetched for that `rev` contains the package, so `cargo_gen_config` emits that package's path patch. The manifest line stays a git dependency. This covers `craft-update` on the nine apps whose ebuild dropped it.
- A Cargo GitTag rewrite omits a lock git package only when every manifest edge for that package is windows-only or wasm-only. A package the Linux set also depends on stays in `GIT_CRATES`, including when a wasm or Windows table names it too (`egui`, `eframe`, `craft-update`).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `storytold-craft-apps`: Patch-pin rewrite resolves a crate inside a checkout already fetched for that rev. Prepare dies only when the crate is not there. Direct git lines stay git lines, and a missing package found in that checkout is registered on `GIT_CRATES` before Cargo's config patch is generated. EffectCraft's Linux-git rule gains the dual-target case (`egui`, `eframe`, `craft-update`).
- `cargo-crates-assets`: `GIT_CRATES` keeps a lock git package that the Linux dependency set names, and omits a package only when every edge is windows-only or wasm-only.

## Non-goals

- Republishing the twelve atoms, or hand-editing their `GIT_CRATES` blocks and Manifests. The ebuilds already fetch the egui and craft-libs archives.
- Rewriting workspace git dependency lines into path dependencies.
- Changing `::gentoo` `cargo.eclass`, USE flags, `src_test`, or the deferred upstream test failures.
- Packaging PhotoCraft's next bump. `media-gfx/photocraft` is still `0.5.0-r1` and does not pin this egui rev. The helper change applies to it only if a later ebuild calls the same function.

## Impact

- Overlay `eclass/mndz-cargo.eclass` (`mndz-cargo_rewrite_patch_git_pins`), read at emerge time. No new distfile.
- Manager `stripWindowsOnlyGitCrates` / `windowsOnlyDepNames`, and the Storytold patch-pin tests.
- Living specs `storytold-craft-apps` and `cargo-crates-assets`.
- The operator re-emerges the twelve atoms after the eclass change. The agent does not run `sudo`. The nine apps that lost `craft-update` (EffectCraft, FilmCraft, SoundCraft, FigCraft, LightCraft, VectorCraft, PdfCraft, DesignCraft, WordCraft) need the direct-git registration or compile will fetch GitHub under the network sandbox. CADCraft, DeckCraft, and GridCraft already keep that key.
