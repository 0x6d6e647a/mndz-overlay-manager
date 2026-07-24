## Context

Part 2 of 8. After pure-helper dedupe, rename multi-ecosystem planning types and modules so code matches OpenSpec `runtime-lanes` vocabulary. Go-specific code stays under `Update.Go.*`.

Misleading names today:

- `GoLanePlan` used for all DepsAndAssets ecosystems
- `Update.Go.Tree` holds `RuntimeCeilings`, nodejs/bun/rust discovery, not only Go
- Aliases: `GoCeilings`, `GoEbuildMeta`, `type LanePlan = GoLanePlan`
- `laneLabel` defaults atom to `dev-lang/go`

## Goals / Non-Goals

**Goals:**

- Mechanical rename/re-home with **no planning behavior change**.
- Hard cut of old names in production sources and tests (app library).
- New Apply split (part 3) lands on cleaned names.

**Non-Goals:**

- Changing ceiling discovery algorithms, candidate selection, or labels’ operator-visible format (except fixing any accidental wrong default atom).
- Spec rewrites that invent library module names as requirements.

## Decisions

### D1: Plan type name → `RuntimeLanePlan`

**Choice:** Rename `GoLanePlan` → `RuntimeLanePlan`. Drop redundant `type LanePlan = …` **or** keep `LanePlan` only as a short alias if it reduces noise — prefer **one** name: `RuntimeLanePlan`.

**Rationale:** Matches “runtime lanes” language; avoids Go-only reading.

### D2: Module re-home for ceilings

**Choice:** Move general ceiling/KEYWORDS API from `Update.Go.Tree` to `Update.Runtime.Ceilings` (module name may be `Update.Runtime.Tree` if preferred at apply time; document the chosen name in tasks). Leave Go-only helpers that are truly Go-specific either as thin re-exports or in `Update.Go.Version` / plan modules.

**Rationale:** Tree/ceilings are multi-runtime; Vendor/ModFetch stay Go.

**Alternatives:** Keep file path `Update/Go/Tree.hs` but rename types only (weaker; audit wanted re-home).

### D3: Hard cut, no deprecation aliases

**Choice:** Update all call sites in one change; no long-lived `GoLanePlan` re-export.

**Rationale:** Not a published library; aliases prolong confusion.

### D4: Labels

**Choice:** Call sites that need labels pass the runtime atom via `laneLabelWith` (or rename to `runtimeLaneLabel`). Remove or stop using go-default `laneLabel` for multi-ecosystem paths.

### D5: Cabal modules

**Choice:** Replace `Update.Go.Tree` with the new module in `exposed-modules` / weeder roots for this intermediate state; part 5 will shrink exports later.

## Risks / Trade-offs

- **[Risk] Wide mechanical churn / merge pain** → Mitigation: land only after part 1; one focused PR; run full tests.
- **[Risk] Missed alias leaves Go* fossil** → Mitigation: repo-wide grep gate in tasks (`GoLanePlan`, `GoCeilings`, etc.).
- **[Risk] Spec authors start requiring module names** → Mitigation: living specs stay operator-facing; this change does not add library-name requirements.

## Migration Plan

1. Add new module; move code; fix imports.
2. Rename plan type project-wide.
3. Remove aliases; grep-clean.
4. `hk check`.
5. Archive before part 3.

Rollback: git revert.

## Open Questions

- Exact new module name (`Update.Runtime.Ceilings` vs `Update.Runtime.Tree`) — resolve at apply time; prefer `Ceilings` if the module is mostly ceiling discovery.
