## 0. Prerequisites

- [x] 0.1 Confirm `pure-helpers-dedupe` is applied and archived (or equivalent base branch)

## 1. Runtime ceilings module

Chosen name: **`Update.Runtime.Ceilings`** (was `Update.Go.Tree`).

- [x] 1.1 Create `Update.Runtime.Ceilings` (or chosen name) and move general ceiling/KEYWORDS discovery API out of `Update.Go.Tree`
- [x] 1.2 Update cabal `exposed-modules` / imports project-wide
- [x] 1.3 Leave Go-specific modules (`Vendor`, `ModFetch`, `Version`, etc.) under `Update.Go.*`

## 2. Plan type rename

- [x] 2.1 Rename `GoLanePlan` → `RuntimeLanePlan` across library and tests
- [x] 2.2 Remove aliases (`GoCeilings`, `GoEbuildMeta`, redundant `LanePlan` alias) after call sites update
- [x] 2.3 Ensure multi-ecosystem paths use `laneLabelWith` / explicit runtime atom (no silent go-default for non-Go)

## 3. Verify

- [x] 3.1 Repo grep clean for `GoLanePlan`, `GoCeilings`, and other retired aliases in `src/` and `test/`
- [x] 3.2 `cabal test all` green
- [x] 3.3 `hk check` green

## 4. Specs and handoff

- [x] 4.1 Keep `runtime-lanes` multi-ecosystem delta aligned with label behavior
- [x] 4.2 Sync `runtime-lanes` into main specs at archive
- [x] 4.3 Ready to archive; next change: `split-apply-module`
