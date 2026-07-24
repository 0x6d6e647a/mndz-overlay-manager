## Context

A quality audit found the same pure helpers reimplemented across Apply, Check, Deps.Plan, Go.Plan, and six HTTP-facing modules. This is part 1 of 8 in the post-audit program: a behavior-preserving dedupe so later rename/split work touches one definition per helper.

Current duplicates (non-exhaustive):

| Helper | Locations |
|--------|-----------|
| `renderPVNoRev` | Apply, Check, Deps.Plan, Go.Plan (local) |
| `samePV` / EQ via `comparePV` | Apply (multiple), Check, EbuildEdit, Go.Lanes |
| `tryHttp` | Http, GitHub, Npm, Npm.Cache, Assets.Release, Go.ModFetch |
| quote strip | Cargo.Msrv, Go.Tree, EbuildEdit |
| Cargo MSRV fetch | Check `fetchCargoMsrv` vs Apply `fetchCargoMsrvForPV` |

## Goals / Non-Goals

**Goals:**

- Single definition for each helper above.
- Call sites import the shared definition.
- Full test suite and `hk check` remain green.
- Zero intentional behavior change.

**Non-Goals:**

- Apply split, runtime renames, error ADTs, API encapsulation, progress UX, test modularization, Stan tightening (later parts).
- Introducing new product dependencies beyond existing packages.
- Unifying *all* text utilities project-wide beyond the listed helpers.

## Decisions

### D1: Home for version helpers → `Overlay.Version`

**Choice:** Export `renderPVNoRev` and `eqPV` (name may be `samePV` if existing tests prefer that spelling) from `Overlay.Version` next to `comparePV` / `renderPV`.

**Rationale:** PV rendering without revision and PV equality are version-domain pure functions; Overlay.Version is already the shared pure core with no Update dependency.

**Alternatives:** `Update.Types` (more Update-centric; Overlay already depends nothing on Update); new `Update.VersionUtil` (extra module for two functions).

### D2: HTTP catch helper → extend `Update.Http` or tiny shared module

**Choice:** Prefer exporting `tryHttp` (or `catchHttp`) from `Update.Http` if that does not create import cycles; otherwise add `Update.Http.Catch` with only the catch helper and re-export from Http.

**Rationale:** All call sites already do the same `catch SomeException → Left (T.pack (show e))` pattern.

**Alternatives:** Copy into a `Util` dumping ground (worse); depend on a third-party helper (unnecessary).

### D3: Quote strip → small pure function near first consumer or shared text helper

**Choice:** One `stripSurroundingQuotes :: Text -> Text` (double and single) used by Cargo.Msrv, Go.Tree KEYWORDS parse, and EbuildEdit. Prefer placing it in a minimal shared pure module if needed (`Update.TextUtil`) or in `Overlay.Version` only if it stays version-unrelated — prefer **`Update.TextUtil`** or keep under the module that already owns KEYWORDS parse and re-export carefully.

**Rationale:** Behavior is identical enough to share; slight differences (double-only vs double+single) should be normalized to one total function.

### D4: Cargo MSRV fetch → one shared function

**Choice:** One implementation that tries subdirectory candidates (package subdir, lock subdir, root), parses `rust-version`, normalizes, and returns `Maybe`/`Either` consistently. Check and Apply both call it; Apply may still pass optional donor ebuild content for fallback if that is current Apply-only behavior — preserve that as an optional parameter rather than forking the whole loop.

**Rationale:** Audit called out divergent loops as drift risk.

### D5: No new public product API marketing

Helpers may become exports of existing modules; part 5 will shrink overall exposure. Do not add README docs for these helpers.

## Risks / Trade-offs

- **[Risk] Subtle behavior drift when unifying quote-strip or MSRV try-order** → Mitigation: keep existing unit tests; add a focused test if try-order is specified in comments; prefer the more complete try-order when merging.
- **[Risk] Import cycles (Http ↔ others)** → Mitigation: catch helper in a leaf module if needed.
- **[Risk] Name collision (`samePV` local where clauses)** → Mitigation: export `eqPV` and replace locals systematically.

## Migration Plan

1. Add shared definitions.
2. Switch call sites module-by-module.
3. Delete dead local definitions.
4. `cabal test all` / `hk check`.
5. Archive; unlock part 2.

Rollback: revert the change commit; no data migration.

## Open Questions

None blocking — implementation may pick `eqPV` vs `samePV` naming at apply time for consistency with the majority of call sites.
