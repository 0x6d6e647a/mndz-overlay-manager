# Tasks

## 1. Prepare resolves unkeyed pins

- [x] 1.1 Extend `mndz-cargo_rewrite_patch_git_pins` in `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay/eclass/mndz-cargo.eclass` so a one-line `[patch.*]` git pin with no `GIT_CRATES` key is rewritten from the `[package].name` inside exactly one archive root already fetched for that full commit. Zero roots or two roots die before `src_compile`. Do not add a `GIT_CRATES` key for a pin rewritten to `path`. Do not commit the overlay. Verify the eclass still has no `EXPORT_FUNCTIONS`, still dies on a missing `Cargo.toml` and on a non-one-line pin, and the new lookup matches `[package].name` rather than the directory name.
- [x] 1.2 After that rewrite, register a workspace git dependency that stayed `git` when `Cargo.lock` records it at that commit and exactly one such archive root contains its `Cargo.toml`. Copy the sibling git URL and store the directory with `%commit%`. Die when the lock records it and the root count is not one, and leave the workspace line unchanged. Leave a package the lock does not record unregistered. Call `cargo_gen_config` again only when a key was added. Verify the eclass does not rewrite those workspace lines to `path`, and that `cargo_gen_config` is not called when no key was added.
- [x] 1.3 The operator, not the agent, emerges `=media-video/effectcraft-0.18.0` and `=app-text/pdfcraft-0.15.0`. The agent does not run `sudo`. Verify both pass `src_prepare` and install. EffectCraft must not die on the `egui` pin. PdfCraft must not die on `egui_system_font_provider`. Neither build may fetch `craft-update` from GitHub. Leave this unchecked until the operator reports those two results.

## 2. Keep Linux git crates on the next rewrite

- [x] 2.1 Change `stripWindowsOnlyGitCrates` so a lock git name is dropped only when some `collectClassifiedDeps` edge is `TIgnore` and no edge in the collected bodies is any other class. Keep the MSRV walk unchanged, and do not treat `[dev-dependencies]` as keep-edges. Extend `testCargoGitCratesWindowsOmit` in `test/Test/EbuildEdit.hs`: `mxc` stays dropped, a wasm-only git crate is dropped, and a crate named from both a Linux dependency and a wasm or Windows table stays, including when those edges are in different manifests. Verify with `just test GitCrates`.
- [x] 2.2 Run `just check` and `openspec validate fix-storytold-unkeyed-git-pins --type change --strict`. Verify both exit 0.

## Workflow follow-up

- The operator re-emerges the other ten atoms from the 2026-10-29 failure, which use the same helper: FilmCraft 0.14.0, SoundCraft 0.14.0, CADCraft 0.14.0, FigCraft 0.12.1, LightCraft 0.15.0, VectorCraft 0.18.0, DeckCraft 0.12.0, DesignCraft 0.14.0, GridCraft 0.13.0, WordCraft 0.12.0.
- The operator signs the overlay eclass commit. The agent does not commit the overlay unless asked.
- Archive this change after the two proof emerges and the manager gate are green. Sync the deltas into `storytold-craft-apps` and `cargo-crates-assets` at archive time.
