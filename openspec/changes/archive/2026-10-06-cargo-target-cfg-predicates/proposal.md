# Proposal

## Why

`outdated` for `dev-util/codex` spends minutes walking every `rust-v` release since `0.154.0`. The cli manifest's musl `cfg` uses `target_env` and a CPU `target_arch`, which the tag-floor walker treats as unparsed, so each newer tag is incomplete, fills no Rust lane, and is still downloaded in full before the probe continues.

## What Changes

- Recognize `target_env` and a fixed set of CPU `target_arch` values when classifying Cargo `[target]` tables for the tag floor and the source-tree harvest.
- `target_env = "musl"` does not hold for any modeled family. `target_env = "gnu"` holds for Linux only. `target_env = "msvc"` holds for Windows. Any other `target_env` value does not hold.
- `wasm32` and `wasm64` stay wasm-only. The listed CPU arches hold for every non-wasm family. A `target_arch` outside that list still makes the candidate incomplete.
- Codex's musl `tikv-jemallocator` table then matches no modeled family and is ignored, so the newest tag can complete. A floor that fits every ceilinged lane stops the newest-first probe on that tag.
- An incomplete candidate still walks the rest of its closure. A later malformed manifest or transport error still fails the plan.

## Non-goals

- Stop fetching a closure at the first incomplete mark.
- Parallel manifest GETs, or shallow-cloning a tag during `outdated`.
- A musl userspace family, or per-arch Rust lanes.
- Classifying `target_feature`, `target_vendor`, `target_endian`, `panic`, or any other predicate.
- Changing the check-cache TTL, candidate-version filter, or lane early-stop rule.

## Capabilities

### New Capabilities

### Modified Capabilities

- `cargo-crates-assets`: Cargo `[target]` cfg classification for `target_env` and CPU `target_arch` during tag-floor discovery and source-tree harvest.

## Impact

- `Update.Cargo.Msrv` cfg evaluation, shared by `outdated`, `update` planning, and full-path source harvest.
- Tests for the musl table and the env/arch table. No CLI, config, or dependency change.
- `dev-util/codex` planning can select a tag newer than `0.153.4` when that tag's floor fits the Rust ceilings. Other Cargo packages use the same classifier.
