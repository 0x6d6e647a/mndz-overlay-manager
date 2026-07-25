## Why

`Update.Apply.Materialize` is the largest absolute uncovered module (~40% expressions, ~900+ uncov). Existing apply integration is Go-heavy; npm, bun, and cargo Materialize branches remain cold despite equal production criticality. Wave 4 maximizes apply/materialize coverage for **all ecosystems** with Unit and Integration tests using injectable Ops.

## What Changes

- Add **Unit** and **Integration** tests for Materialize / apply deps-and-assets paths:
  - **Npm, Bun, Cargo** full materialize (and reuse where product supports it), progress sequence assertions mirroring existing Go full/reuse tests
  - **Go** residual Materialize branches only where equal-cost gaps remain after earlier waves
- Use existing seams: `ApplyEnv`, eco `*Ops`, `ReleaseOps`, mock egencache, temp overlays (`Test.Support` patterns).
- Prefer focused test modules over unbounded growth of `Test.Apply` when practical.
- Re-run `./scripts/coverage`; keep `hk check` green.
- **No** operator-visible product behavior change.

## Program context

- **Wave 4 of 5** of the post-HPC coverage-maximization program.
- **Apply order:** after `raise-coverage-check-and-deps-plan`; before `raise-coverage-agents-git-release`.
- **Depends on:** Waves 2–3 recommended (builder + plan fakes compose into apply).
- **Horizon:** Overall ~75% → ~80%+ if Materialize uncov drops hard.

## Non-goals

- SSH/GPG process depth, production Git/Release HTTP residual — Wave 5.
- Live network asset publish.
- Numeric floors/ratchet.
- Changing update-apply operator semantics.
- System tests of the real executable.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `test-coverage`: ADDED requirements that Unit and Integration suites exercise Materialize/apply deps-and-assets paths for npm, bun, and cargo (and documented Go residual) via injectable environments.

## Impact

- **Code:** `test/**` (Apply/Materialize-focused modules); uses existing product injectability, not new production features.
- **Quality:** largest single-module uncov reduction expected; `hk check` green.
- **Docs:** none required (`project-docs` internal-only).
- **Downstream:** Wave 5 polishes agents/HTTP residual with a much higher baseline.
