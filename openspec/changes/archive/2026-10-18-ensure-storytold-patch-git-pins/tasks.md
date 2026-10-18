# Tasks

## 1. Overlay helper

- [x] 1.1 Add `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay/eclass/mndz-cargo.eclass`. Move DesignCraft 0.9.0's `GIT_CRATES` loop and patch-pin Python into `mndz-cargo_rewrite_patch_git_pins` unchanged, as design.md describes. Do not call `default` from the helper and do not `EXPORT_FUNCTIONS`. Do not commit. Verify the eclass defines `mndz-cargo_rewrite_patch_git_pins`, contains `cannot parse patch git pin`, and does not contain `EXPORT_FUNCTIONS`.

- [x] 1.2 Call that helper from `deckcraft-0.8.0.ebuild`, `wordcraft-0.8.0.ebuild`, `effectcraft-0.11.1.ebuild`, and `designcraft-0.9.0.ebuild`. Inherit `mndz-cargo` immediately after the `cargo` token. `src_prepare` calls `default`, then `mndz-cargo_rewrite_patch_git_pins`. DesignCraft drops the inline Python and keeps `default`. Do not add `-r1`. Do not commit. Verify each filename is unchanged, each `src_prepare` body contains no `c3487320`, `ca50d63b`, or `b5467d93` literal, and `designcraft-0.9.0.ebuild` no longer contains `cannot parse patch git pin`.

- [x] 1.3 Regenerate `metadata/md5-cache` for `app-office/deckcraft`, `app-office/wordcraft`, `app-office/designcraft`, and `media-video/effectcraft` with package-scoped `egencache` for repo `mndz`, using the production argv in `Update.Md5Cache` and the overlay checkout as the repo location. Do not run the manager `gencache` command and do not commit. Verify each cache filename is unchanged, its `_md5_` equals `md5sum` of that ebuild, and its `mndz-cargo` digest equals `md5sum` of `eclass/mndz-cargo.eclass`. Verify the four `Manifest` files are unchanged.

- [x] 1.4 Replay the helper on the preserved trees `deckcraft-0.8.0-2026-10-18T00:02:16-07:00`, `wordcraft-0.8.0-2026-10-18T00:02:28-07:00`, and `effectcraft-0.11.1-2026-10-18T09:15:10-07:00`, then run rust-bin 1.98.1 `cargo metadata --offline` with each tree's cargo home. Verify metadata exits 0. Verify deckcraft's `krilla` line is a path ending in `vendor/krilla` and still sets `version = "=0.8.2"`, wordcraft's `krilla` line is a path with no `version` key, and effectcraft's `hayro-syntax` line is a path ending in `vendor/hayro-syntax` and still sets `version = "=0.7.2"`. Verify each `craft-pdf` line still contains `git`, and effectcraft's commented filmcraft patch header is still a comment. Restore each tree's `Cargo.toml` and `Cargo.lock` and verify the restore with `cmp`.

## 2. Manager hook

- [x] 2.1 Add `ensureStorytoldPatchPinHook` and run it after `ensureGitCrateSrcUri` for the Storytold GitTag package names in design.md. Map a hook error to `ApplyHardFail` before ebuild, Manifest, or commit mutation. Verify a Storytold ebuild that declares `GIT_CRATES` and has no `src_prepare` gains `inherit` with `mndz-cargo` immediately after `cargo` and a `src_prepare` that calls `default` then `mndz-cargo_rewrite_patch_git_pins`.

- [x] 2.2 Add `Test/EbuildEdit.hs` cases, named with the prefix `storytoldPatchPinHook`, for a missing phase, an existing phase whose body survives, an already-correct ebuild left unchanged, no `GIT_CRATES` declaration, `dev-util/codex` left unchanged, and a phase with no `default` returning an error without a rewritten body. Add a test that the package-name set equals the Hardcoded Cargo GitTag policies whose GitHub owner is `storytold`, and that `craft-fonts` and `codex` are absent. Verify `just test storytoldPatchPinHook` exits 0.

- [x] 2.3 Run `just check` and verify it exits 0. Verify this change does not edit `README.md`, `CONTRIBUTING.md`, `AGENTS.md`, or `openspec/changes/python-uv-deps-assets/`.

## 3. Change check

- [x] 3.1 Run `openspec validate ensure-storytold-patch-git-pins --type change --strict` and verify it exits 0.

## Workflow follow-up

- The operator, not the agent, re-emerges `=app-office/deckcraft-0.8.0`, `=app-office/wordcraft-0.8.0`, and `=media-video/effectcraft-0.11.1`. That emerge is the compile check.
- Do not commit the overlay or the manager unless the operator asks. Overlay commits stay signed by the operator.
- Archive this change after that emerge succeeds, syncing the `storytold-craft-apps` and `cargo-crates-assets` deltas into the living specs.
