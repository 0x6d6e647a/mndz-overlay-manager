## Context

See `proposal.md` for why. Living SoT is ~5k lines across 33 domains; hygiene targets residue, policy multi-home, and `test-coverage` wave archaeology. Product code (`src/Update/Hardcoded.hs` and apply paths) already matches the intended canonical policy; this change is **spec/doc structure only**. Apply means editing living `openspec/specs/**` via these deltas (and archive merge later), not Haskell refactors.

## Goals / Non-Goals

**Goals:**

- Single authoritative package policy narrative in `update-apply`.
- No forbidden delta residue phrases in living SoT after apply.
- `test-coverage` reduced to durable engine + isolation + excludes + reports + entrypoint + floors + one surface-coverage requirement.
- Go domains keep ecosystem-specific behavior only; shared spine stays in `deps-assets` / `runtime-lanes` / `update-apply`.
- Requirement subjects prefer “program/CLI” over “library” and avoid helper-name pins where scrubbed.
- `openspec validate --change sot-hygiene` clean; post-apply living validate clean.

**Non-Goals:**

- Product code, tests, quality gates, or operator docs changes (unless a false statement is found — unexpected).
- Capability path renames (`go-vendor-assets` stays).
- Relocating seed/overlay-only domains.
- Perfect de-duplication of every cross-reference scenario.

## Decisions

### 1. Canonical policy home = `update-apply`

**Choice:** Expand “Hardcoded policy covers known overlay packages” to the full map (including badger, opencode, usage `cli`, autolith) and remove the duplicate autolith-only requirement. Point `deps-assets` and `go-vendor-assets` away from owning a second list.

**Alternatives:** New `package-policy` capability — rejected as extra domain for one map. Keep multi-home lists “in sync by discipline” — already failed (deps-assets omitted badger/opencode).

### 2. test-coverage collapse via REMOVED + one ADDED

**Choice:** Keep HPC engine, isolation rows, excludes, reports, floors (renamed off “phase-one”), entrypoint; remove all Wave-N / residual / per-wave floor requirements; add one consolidated surface-coverage requirement that preserves the *what* of the old suite obligations without change-era structure.

**Alternatives:** Leave waves as historical documentation — rejected (agent context cost). Drop surface obligations entirely — rejected (would weaken contributor contract).

### 3. Exact-set only under `runtime-lanes` (+ apply multi-lane)

**Choice:** Remove Go-only exact-set from `go-tree-lanes`; keep KEYWORDS collapse scenarios in `go-tree-lanes` with explicit pointer to shared tilde-only policy so Go plan examples remain local.

**Alternatives:** Remove KEYWORDS assembly from go-tree-lanes too — more aggressive; deferred to keep Go plan examples readable.

### 4. Residue scrub is in-place wording, not behavior

**Choice:** `overlay-test-use` scenarios inspect permanent overlay truth (“when inspected”) instead of “after this change”; revision-bump scenarios stay normative without change-scoped WHEN clauses. SSH remote rule drops “as part of this change”. Progress “phase-one” renames to package-apply.

### 5. Apply workflow for this change

**Choice:** Tasks are mechanical: merge each delta into living SoT (or implement via archive process), run `openspec validate`, run banned-phrase `rg`, confirm policy list matches `Hardcoded.hs`. No `cabal` work unless validate tools require it.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| MODIFIED deltas lose scenarios if incomplete | Full requirement blocks for MODIFIED (cli-activity multi-progress fully restated) |
| Archive merge of many REMOVED test-coverage reqs is large | Single ADDED consolidated req documents migration path in each REMOVED |
| Over-thinning Go domains confuses readers | Keep go.mod ceilings, vendor materialize, KEYWORDS examples |
| RENAMED + MODIFIED for same req confuses tooling | Follow OpenSpec RENAMED then MODIFIED with **new** title in MODIFIED body |
| Accidental product drift claims | Explicit non-goal: no code; post-check only specs vs Hardcoded.hs |

## Migration Plan

1. Land deltas under `openspec/changes/sot-hygiene/`.
2. On apply: update living `openspec/specs/<cap>/spec.md` to match deltas (or archive-merge when archiving).
3. Validate change + living specs.
4. Grep living SoT for banned phrases and partial policy lists.
5. Archive when green; no runtime deploy.

## Open Questions

None blocking. Optional later: move seed domains out of manager SoT; rename `go-vendor-assets` path.
