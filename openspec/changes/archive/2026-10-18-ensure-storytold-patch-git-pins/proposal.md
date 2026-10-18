# Proposal

## Why

`app-office/deckcraft-0.8.0`, `app-office/wordcraft-0.8.0`, and `media-video/effectcraft-0.11.1` die in `src_compile` on rust-bin 1.98.1. Each manifest pins a git crate under `[patch.crates-io]`, the ebuild already unpacked that checkout, and Cargo tries to clone it again while offline. DesignCraft already rewrites that kind of pin, and `pycargoebuild` only keeps the rewrite when the previous ebuild had it. These three donors did not.

## What Changes

- Share DesignCraft's one-line `[patch.*]` git-pin rewriter as an overlay eclass helper, and call it from `src_prepare` in the three failed ebuilds and in DesignCraft.
- Keep each of those four ebuilds at its current PVR. None of the three failed versions merged. DesignCraft's installed build already matches the helper's result, so it does not need a rebuild.
- When a Cargo rewrite writes a Storytold craft ebuild that declares `GIT_CRATES`, leave that ebuild calling the helper. An ebuild that already has `src_prepare` gains the call after `default` and keeps the rest of that phase. An update that cannot insert the call safely fails before mutation.
- Leave workspace git dependencies outside `[patch.*]` on the `cargo.eclass` patch. A pin the helper cannot place still dies before `src_compile`.

## Capabilities

### New Capabilities

### Modified Capabilities

- `storytold-craft-apps`: every Storytold craft app rewrites one-line `[patch.*]` git pins from `GIT_CRATES` onto unpacked paths before compile, and fails closed when a pin cannot be rewritten. Direct git dependencies stay unchanged.
- `cargo-crates-assets`: a Cargo rewrite of a Storytold craft ebuild that declares `GIT_CRATES` emits a call to that helper. Codex and other non-Storytold Cargo packages stay as they are.

## Impact

- Overlay eclass `mndz-cargo`, plus in-place edits of `deckcraft-0.8.0.ebuild`, `wordcraft-0.8.0.ebuild`, `effectcraft-0.11.1.ebuild`, and `designcraft-0.9.0.ebuild`, with their package-scoped md5-cache.
- Manager ebuild rewrite (`src/Update/EbuildEdit.hs` and its tests), beside the existing git-crate fetch line.
- Proof is an offline `cargo metadata` on the three preserved failed work trees, then the operator re-emerges those three atoms. The agent does not run `emerge`.
- README, CONTRIBUTING, and AGENTS stay unchanged. This does not change the operator CLI, configuration, or the quality pipeline.

## Non-goals

- Codex. `dev-util/codex` keeps its own three-name patch rewrite and does not gain this helper.
- Other non-Storytold Cargo packages.
- Editing Storytold ebuilds that already merged and have no `[patch.*]` git pin. Their next Cargo rewrite adds the call.
- Changing `cargo.eclass` or `CARGO_HOME/config.toml`. A second `[patch.crates-io]` entry for the same crate is a double patch.
- Accepting multiline patch tables, or pins that use `branch` or `tag` instead of `rev`. Those still die in `src_prepare` and name the crate.
- A `-r1` revision, wrapping `cargo_src_compile`, or work under the active `python-uv-deps-assets` change.
