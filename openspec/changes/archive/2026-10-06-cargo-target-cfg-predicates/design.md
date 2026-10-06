# Design

## Context

See proposal.md for why Codex `outdated` walks every `rust-v` tag since `0.154.0`. Tag-floor discovery and source-tree harvest both call `probePolicyTagFloor` in `Update.Cargo.Msrv`. `atomHolds` already treats an unknown `target_os` as not holding, which is how `cfg(not(target_os = "android"))` stays active. `target_arch` is recognized only for `wasm32` and `wasm64`. `target_env` is unrecognized, so the whole cfg evaluates to incomplete. `planCargo` drops an incomplete tag without filling a lane. The shared newest-first probe keeps going until every ceilinged lane has a package, and an incomplete tag does not stop the rest of that tag's closure fetch.

## Goals / Non-Goals

**Goals:**

- Extend the existing cfg evaluator so the predicates in the cargo-crates-assets delta are classified.
- Keep one code path for tag floor and source-tree harvest.
- Cover the new cases with the in-memory floor fixtures already used for target tables.

**Non-Goals:**

- A second classifier, a musl family, or per-arch lanes.
- Stopping a closure fetch at the first incomplete mark.
- Parallel GETs or a clone during `outdated`.
- Recognizing predicates other than `target_env` and `target_arch`.

## Decisions

1. **Extend `atomHolds`.** The Android `target_os` case already lives there, and both planning and harvest use it. A parallel evaluator would drift.

2. **Unknown `target_env` values do not hold.** Same rule as an unknown `target_os`: the atom is `Just False`, so `not(target_env = "...")` still evaluates. `gnu` holds only for Linux. `msvc` holds only for Windows. `musl` and every other value hold for no family. Alternative considered: leave unknown env values unparsed. That preserves fail-closed behavior and brings the multi-tag walk back for the next env name.

3. **Listed CPU arches hold on every non-wasm family and do not hold for wasm.** `cfg(target_arch = "x86_64")` then matches Linux, so the table is active and can raise the floor. `wasm32` and `wasm64` stay wasm-only, so a wasm-only table stays ignored. Alternative considered: treat every non-wasm arch string as holding. That would hide typos. An unlisted value stays unparsed and the candidate stays incomplete.

4. **Do not abort the closure after the first incomplete mark.** A later malformed manifest or transport error must still fail the plan. The speed win is the newest tag becoming complete so the existing lane stop applies, not a shorter failed walk.

5. **Leave manifest fetching as one GET per `Cargo.toml`.** Measure a single newest-tag probe after the predicate change before considering parallelism or a clone.

6. **If `rust-v0.160.1` still has an unparsed predicate outside these two, stop.** Report that predicate. Do not widen this change's predicate set to absorb it.

## Risks / Trade-offs

- [A musl-only path crate is invisible to the floor] → Accepted. The modeled Linux family is the non-musl userspace. The Codex table that triggered this only names `tikv-jemallocator`.
- [A CPU-arch table is active on every non-wasm family, so an `x86_64`-only path crate can raise the floor used for other arches] → Accepted. The floor can only go up.
- [An unknown `target_env` no longer fails closed] → Same tradeoff as the unknown-`target_os` rule. Unlisted `target_arch` values still fail closed.
- [`rust-v0.160.1` may contain another unparsed cfg deeper than `cli/Cargo.toml`] → The probe task checks that tag. A foreign predicate stops this change instead of being folded in.

## Migration Plan

No config or on-disk migration. The next `outdated` or `update` plan uses the new classification. Rollback is reverting the evaluator and the spec delta. Successful plans remain subject to the existing check-cache TTL.

## Open Questions

None. The predicate table, the full-closure rule, and the one-GET fetch strategy are decided.
