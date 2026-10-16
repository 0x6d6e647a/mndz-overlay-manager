# Tasks

## 1. DesignCraft src_prepare

- [x] 1.1 Add `src_prepare` to `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay/app-office/designcraft/designcraft-0.8.0.ebuild`. Call `default`, then rewrite one-line `[patch.*]` git pins from `GIT_CRATES` as design.md describes. Die when a pin's name and `rev` are absent from `GIT_CRATES` or the unpacked `Cargo.toml` is missing. Leave `[workspace.dependencies]` git lines unchanged. Do not add `-r1`. Do not commit. Verify the function body contains no `b5467d93` or `3d51077` literal, the ebuild filename is still `designcraft-0.8.0.ebuild`, and `craft-print` is not a rewrite target.

- [x] 1.2 Replay that rewrite on the preserved work tree `/var/tmp/portage/app-office/designcraft-0.8.0-2026-10-15T18:51:20-07:00/work/designcraft-0.8.0/Cargo.toml` using the ebuild's `GIT_CRATES` paths, then run Cargo 1.97.1 `cargo metadata --offline` with the work tree's cargo home and the eclass config paths rewritten to that directory. Verify metadata exits 0, the manifest's `hayro` and `winit` lines are path dependencies, and its `craft-print` and `craft-ui` lines still contain `git`. Restore that tree's `Cargo.toml` and `Cargo.lock` afterward and verify the restore with `cmp`.

## 2. Change check

- [x] 2.1 Run `openspec validate fix-designcraft-patch-git-pins --type change --strict` and verify it exits 0. Verify this change does not edit manager Haskell, `README.md`, `CONTRIBUTING.md`, or `AGENTS.md`. `just check` is not the gate: no manager source changes.

## Workflow follow-up

- The operator, not the agent, re-emerges `=app-office/designcraft-0.8.0`. That emerge is the compile check.
- Archive this change after that emerge succeeds, syncing the `storytold-craft-apps` delta into the living spec.
