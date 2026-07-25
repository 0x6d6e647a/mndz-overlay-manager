## Context

Locked: public `*HttpLbs` (T5-A); GitHub single-page + multi-page pagination in one wave (T6 A+B); Npm.Cache registry-only (T7-A). Existing patterns: `HttpLbs`, `fetchNpmWithHttp`, Release `*HttpLbs`, `Test.HttpFake.fakeResponse`.

## Goals / Non-Goals

**Goals:**

- Heat production GitHub / npm registry / go.mod HTTP with Unit Fake-HTTP
- Full GitHub list path including pagination recursion
- No live network in gate

**Non-Goals:**

- Process builders; agents; apply spine; floors

## Decisions

### D1: Release-style duals

**Choice:** `fooHttpLbs` implementations + thin Manager wrappers calling them. Export duals where Unit imports them.

### D2: GitHub scope

**Choice:** `fetchGitHubWith` (release then tags fallback), `listGitHubVersionsWith` with **multi-page** fixtures (100-tag page + short page or equivalent product pagination rule), pure parse helpers already partly warm stay regression-safe.

### D3: Npm registry only

**Choice:** `listNpmVersions`, `fetchNpmEnginesNode`, related JSON parsers. Do **not** migrate pack/install/tar (process wave).

### D4: Go.mod fetch

**Choice:** `fetchGoModAtTag` / `httpGetText` via HttpLbs dual + auth header edges; disk cache paths may already be warm—focus on HTTP body residual.

### D5: Unit isolation

**Choice:** All Fake-HTTP cases Unit. No Integration requirement for this wave.

### D6: Success metric

**Choice:** Gates green; guidance ~+2.5–4.5 Overall expr; no floors.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Large pagination fixtures | Generate programmatically in test; assert page param |
| Public export growth | Only duals tests need; no unused exports (weeder) |
| Overlap with process wave on Npm.Cache | Hard split: registry vs process |

## Migration Plan

1. Duals + production wiring.
2. Unit matrices including pagination.
3. Coverage + hk check.
4. Archive; continue agents or apply residual.

## Open Questions

None blocking.
