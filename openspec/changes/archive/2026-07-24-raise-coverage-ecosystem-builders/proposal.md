## Why

After pure/CLI coverage gains, the largest remaining zeros are DepsAndAssets ecosystem builders: `Update.Npm.Cache`, `Update.Bun.Cache`, and `Update.Cargo.Crates` sit near 0% expression coverage while being equally production-critical with Go. Wave 2 exercises pure helpers and injectable builder Ops for all three ecosystems before plan/apply integration.

## What Changes

- Add **Unit** (and light **Integration** where natural) tests for **npm, bun, and cargo equally**:
  - Pure helpers: engines/version gates, version-too-old messages, naming constants (e.g. `crateTarballPrefix`), package.json / engines parsers as exported
  - Builder paths: `buildNpmDepsTarball`, `buildBunDepsTarball`, `buildCargoCratesTarball` driven via **fake `*Ops`** (success, failure, progress callbacks)—mirror Go injectability style
- Wire new cases into existing tasty Unit/Integration groups; prefer new focused test modules over growing `Test.Apply` further if file size hurts.
- Re-run `./scripts/coverage`; keep `hk check` green.
- **No** operator-visible product behavior change.

## Program context

- **Wave 2 of 5** of the post-HPC coverage-maximization program.
- **Apply order:** after `raise-coverage-pure-and-cli`; before `raise-coverage-check-and-deps-plan`.
- **Depends on:** Wave 1 recommended (not hard-blocked, but baselines cleaner after pure wins).
- **Horizon:** Overall ~55% → ~62–65% expressions if builders leave 0%.

## Non-goals

- Full `planDepsPackageWithProgress` / outdated Check spine — Wave 3.
- Full Materialize `applyDepsAndAssets` publish/reuse per eco — Wave 4.
- SSH/GPG/Release HTTP residual — Wave 5.
- Live network builds against real npm/crates.io/GitHub.
- Numeric floors/ratchet.
- Privileging Go over npm/bun/cargo (Go builder residual only if equal-cost and already partial).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `test-coverage`: ADDED requirements that Unit (and Integration where used) exercise npm, bun, and cargo cache/builder surfaces via injectable Ops, not production network.

## Impact

- **Code:** `test/**` (new or extended modules for ecosystem builders); may use existing `BunCacheOps` / `NpmCacheOps` / `CargoOps` without product API growth.
- **Quality:** coverage report must improve zero-modules for the three ecosystems; `hk check` green.
- **Docs:** none required under `project-docs` internal-only rule.
- **Downstream:** enables Wave 3/4 to call builders without starting from total darkness.
