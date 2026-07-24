## Why

OpenSpec and multi-ecosystem planning speak in runtime-lane terms (Go, Npm, Bun, Cargo ceilings and plans), but library types and modules still use Go-centric names (`GoLanePlan`, `Update.Go.Tree` for all runtimes, `GoCeilings`, go-default `laneLabel`). That mismatch misleads every future edit and fights the living `runtime-lanes` / `go-tree-lanes` split.

## What Changes

- Rename multi-ecosystem plan type `GoLanePlan` → `RuntimeLanePlan` (or promote `LanePlan` as the sole name and remove the Go-prefixed alias).
- Re-home general ceiling/KEYWORDS discovery API out of a Go-only mental model (e.g. `Update.Go.Tree` general surface → `Update.Runtime.Ceilings` or equivalent); keep Go-specific modules (`Vendor`, `ModFetch`, `Version`, Go-only plan bits) under `Update.Go.*`.
- Remove or retire historical aliases (`GoCeilings`, `GoEbuildMeta`, redundant `type LanePlan = …`) after call sites update.
- Prefer `laneLabelWith atom` (or equivalent) so labels do not silently default to `dev-lang/go`.
- Update all library and test call sites in one hard cut (app library, not a published Hackage API).
- **No operator-visible behavior change** when labels already carry the correct runtime atom.

## Program context

- **Part 2 of 8** of the post-audit quality program.
- **Apply order:** after `pure-helpers-dedupe`; before `split-apply-module`.
- **Depends on:** `pure-helpers-dedupe` (recommended; land and archive first).

## Non-goals

- No Apply file split (part 3).
- No planning algorithm changes (ceilings, candidates, lane selection, prune).
- No structured error ADTs (part 4).
- No CLI/help/README changes unless an operator-facing string incorrectly hard-codes Go-only language (not expected).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `runtime-lanes`: Clarify that runtime-lane planning and operator labels are multi-ecosystem (not Go-only), with labels naming the actual runtime atom.

## Impact

- **Code:** `Update.Go.Lanes`, `Update.Go.Tree`, `Update.Go.Plan`, `Update.Deps.Plan`, `Update.Check`, `Update.Apply`, tests under `test/`, cabal `exposed-modules` list.
- **Specs:** living `runtime-lanes` / `go-tree-lanes` remain source of truth; no delta required if requirements already match behavior.
- **Downstream:** `split-apply-module` should create new modules using the cleaned names.
