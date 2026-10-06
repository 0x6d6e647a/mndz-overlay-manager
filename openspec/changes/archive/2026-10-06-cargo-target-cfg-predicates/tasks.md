# Tasks

## 1. Cfg classification

- [x] 1.1 Extend `atomHolds` in `Update.Cargo.Msrv` for `target_env` and `target_arch` as specified in the cargo-crates-assets delta and design.md: `gnu` holds for Linux only, `msvc` holds for Windows only, `musl` and every other env value hold for no family, `wasm32`/`wasm64` stay wasm-only, the listed CPU arches hold for every non-wasm family and not for wasm, and any other `target_arch` stays unparsed. Verify with new `runFloor` cases in `test/Test/Lanes.hs` next to the existing target-table fixtures, covering musl-ignored, gnu-active, msvc-ignored, unknown-env-ignored, the Codex `all(linux, musl, any(x86_64, aarch64))` table, an `x86_64` path crate that raises the floor, a wasm32-only crate that does not, and `nvptx64` incomplete (not selected as `0.0.0`). `just test cargoTargetCfg` passes.

## 2. Newest Codex tag

- [x] 2.1 After 1.1, run `just run outdated dev-util/codex` once. Verify the command exits 0 and the selected target is a complete newest tag whose floor fits the Rust ceilings, rather than falling through older tags because of the musl cfg. If the newest tag is still incomplete for a predicate other than `target_env` or `target_arch`, record that predicate in this change and stop without widening `atomHolds`.

## 3. Gate

- [x] 3.1 Confirm README, CONTRIBUTING, and AGENTS need no edit: this change has no operator CLI, config, quality-pipeline, or agent-process surface. Verify `openspec validate --change cargo-target-cfg-predicates --strict` passes. Leave living `openspec/specs/` untouched; archive performs the SoT merge and residue scrub.
- [x] 3.2 Run `just check` and verify the full gate is green.
