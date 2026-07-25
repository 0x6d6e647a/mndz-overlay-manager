## Context

Domain `*Ops` records already isolate orchestration and are well tested with fakes, leaving production process bodies yellow. Locked decisions: B-1 = ecosystems + simple runners only (T1-A); Process as other-modules + `mk*` heat (T3-A); shell vs exec on request (T4-A); production adapters in scope for % via thin CommandRunner + fakes.

## Goals / Non-Goals

**Goals:**

- Thin CommandRunner seam so production process adapters are Unit-heatable without live tools
- Migrate npm/bun/vendor/cargo process helpers and ebuild/egencache/portageq production runners
- Keep domain `*Ops` for orchestration; do not merge HTTP into Process
- Green `hk check` / `./scripts/coverage`

**Non-Goals:**

- SSH/GPG agents (next process wave)
- Git production migration
- Registry HTTP clients
- Floors, Main scoring, live PATH gate tests

## Decisions

### D1: `Update.Process` internal module

**Choice:** New library module (e.g. `Update.Process`) with `ProcessRequest`, `ProcessResult`, and `CommandRunner` (`run :: ProcessRequest -> IO ProcessResult`). Keep as **other-modules**; export heat surface via domain `mk*Ops` / production constructors.

**Alternatives:** Expose full Process publicly (rejected unless apply proves `mk*` insufficient—then expose only runner+types).

### D2: Shell vs exec on request

**Choice:** Request carries shell vs argv/exec mode so `productionEbuildRunner`-style `shell` commands map without inventing a second runner type.

### D3: `mk*Ops` factory pattern

**Choice:** `productionXOps = mkXOps productionCommandRunner` (or equivalent). Unit tests call `mkXOps scriptedRunner` and exercise builder/runner entry points.

**Rationale:** Production bodies tick when tests force `mk*` paths; domain Ops fakes alone never enter production helpers.

### D4: Migration order inside this change

**Choice:** (1) Process module + production runner, (2) ecosystem caches/builders, (3) ebuild/egencache/portageq, (4) Unit tests.

### D5: Dedup process-shaped helpers when cheap

**Choice:** Share process invocation through CommandRunner; optional small dedup of repeated git-clone/tar patterns only if it reduces duplication without expanding scope.

### D6: Unit ownership

**Choice:** Unit heats adapters. Integration continues using domain Ops fakes for spine tests (later wave).

### D7: Success metric

**Choice:** Tasks green + gates green. Overall expr gain is guidance (~+3–5 if ecosystems+runners warm); no floors.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Denominator growth from Process module | Keep seam thin; heat via mk* |
| Export/weeder fights | other-modules; entrypoint roots only |
| Incomplete migration leaves dual Process styles | Finish all B-1 modules in this change; agents deferred deliberately |
| Scripted fakes drift from real argv | Assert request shape in Unit; mirror production construction |

## Migration Plan

1. Land Process + productionCommandRunner.
2. Migrate ecosystem + runner production paths.
3. Unit scripted tests.
4. `./scripts/coverage` + `hk check`.
5. Archive; next recommended: `registry-http-fakes` and/or `process-agents-residual`.

Rollback: revert module + call-site + test commits.

## Open Questions

None blocking (locked T1/T3/T4).
