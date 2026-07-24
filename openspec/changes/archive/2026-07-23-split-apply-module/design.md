## Context

Part 3 of 8. `Update.Apply` (~1674 LOC) concentrates GitMv, DepsAndAssets materialize (all ecosystems), asset reuse/full publish, overlay write, commit locks, and progress step accounting. Parts 1–2 should already have deduped helpers and runtime-facing names.

Existing tests (GitMv commit-on-success, multi-PV sequential commits, stop-on-hard-fail, reuse vs full, step budgets, overlay lock, md5 gate) are the regression harness.

## Goals / Non-Goals

**Goals:**

- Thin orchestration module; cohesive submodules under `Update.Apply.*`.
- **Behavior-preserving** split: move code first, avoid clever rewrites.
- Keep `ApplyEnv` working; exports needed by Main and tests continue to compile.
- Prefer orchestration file well under the current size (target &lt; ~400 LOC if practical).

**Non-Goals:**

- Changing apply algorithms, commit policy, or progress soft-skip chrome (part 6).
- Introducing error ADTs (part 4) beyond moving types with the code.
- Final public API shrink (part 5).

## Decisions

### D1: Module map

| Module | Responsibility |
|--------|----------------|
| `Update.Apply` | `applyOverlay`, `applyPackagePhase1` (+ tracked), `ApplyEnv`, `foldExitHardFail`, re-exports/wrappers for tests |
| `Update.Apply.GitMv` | `applyGitMv`, `gitMvDo`, md5 require-gate used before GitMv mutation |
| `Update.Apply.Materialize` | `materializeDepsPlan`, `materializeDistfile`, `depsPublishAndOverlay`, reuse/full paths, step budget helpers, progress adapters for vendor/npm/bun/cargo |
| `Update.Apply.OverlayWrite` | `overlayAfterAssets`, template selection, KEYWORDS/BDEPEND/RUST_MIN_VER write, manifest verify after ebuild |
| `Update.Apply.Commit` | `signedOverlayCommit`, `egencacheAndSignedCommit`, unit/prune commit messages |

### D2: Move-first strategy

**Choice:** Extract bottom-up: Commit → GitMv → OverlayWrite → Materialize → leave dispatch in Apply. After each extract: compile + relevant tests.

**Rationale:** Commit has fewest deps; Materialize is largest and depends on OverlayWrite/Commit.

### D3: ApplyEnv stays in `Update.Apply` initially

**Choice:** Keep the 19-field record in the orchestration module; submodules take `ApplyEnv` (or narrower args where already pure).

**Alternatives:** Per-phase env views (later optional cleanup, not required here).

**As implemented:** `ApplyEnv` / `EbuildRunner` / `productionEbuildRunner` live in `Update.Apply.Env` and are re-exported from `Update.Apply`. A sibling env module avoids circular imports (submodules need the record type; orchestration imports the submodules). Public API for Main/tests is unchanged.

### D4: Legacy test entry points

**Choice:** Keep `materializePlan`, `goPublishAndOverlay`, `contentFixNeeded` as thin wrappers on the orchestration module (or Materialize) so existing tests keep importing `Update.Apply`. Part 5 may rehome them.

### D5: No behavior edits mid-move

**Choice:** Do not “improve” soft-skip progress, error strings, or step counts in this change. If a bug is found, fix only if tests already expected the correct behavior.

## Risks / Trade-offs

- **[Risk] Accidental behavior change during large moves** → Mitigation: no logic edits; full apply tests + `hk check` after each extract.
- **[Risk] Circular imports among Apply.*** → Mitigation: Commit leaf; OverlayWrite depends Commit; Materialize depends both; Apply imports all.
- **[Risk] Export list thrash** → Mitigation: temporary re-exports from `Update.Apply` for Main/tests.

## Migration Plan

1. Ensure parts 1–2 archived on the branch base.
2. Extract Commit; fix imports; test.
3. Extract GitMv; test.
4. Extract OverlayWrite; test.
5. Extract Materialize; test.
6. Slim Apply orchestration; full `hk check`.
7. Archive before parts 4–5.

Rollback: git revert of the split commits.

## Final module map (as implemented)

| Module | LOC (approx) | Responsibility |
|--------|--------------|----------------|
| `Update.Apply` | ~174 | `applyOverlay`, `applyPackagePhase1` (+ tracked), `foldExitHardFail`, `needsGoAssetsApply`, re-exports |
| `Update.Apply.Env` | ~65 | `ApplyEnv`, `EbuildRunner`, `productionEbuildRunner` |
| `Update.Apply.Commit` | ~64 | `signedOverlayCommit`, `egencacheAndSignedCommit`, commit message helpers |
| `Update.Apply.GitMv` | ~172 | `applyGitMv`, `gitMvDo`, `requirePackageMd5Cache`, `newEbuildFileName` |
| `Update.Apply.OverlayWrite` | ~181 | `overlayAfterAssets`, `findTemplate` |
| `Update.Apply.Materialize` | ~1128 | Deps plan/materialize, reuse/full publish, step budgets, progress adapters, legacy test facades |

Import graph: Env leaf → Commit → {GitMv, OverlayWrite} → Materialize → Apply orchestration.

## Open Questions

None blocking — exact file names under `Update.Apply.*` may vary slightly if a helper is better as a private submodule.
