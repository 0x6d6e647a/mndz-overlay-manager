## Why

Production process adapters (`productionNpmCacheOps`, `productionBunCacheOps`, `productionVendorOps`, `productionCargoOps`, `productionEbuildRunner`, `productionEgencacheRunner`, production portageq runners, and related helpers) hardcode `System.Process` and stay cold under HPC because tests inject domain `*Ops` fakes. Testmaxxing requires those production bodies to be heatable with scripted process fakes—not live PATH tools—via a thin CommandRunner seam. This is wave 2 of the coverage program (after pure leftovers).

## What Changes

- Introduce a thin **CommandRunner** / process request-result seam (`Update.Process` or equivalent), kept as **other-modules** with heat via `mk*Ops` constructors
- Model **shell vs exec** modes on the request type to match real ebuild-style shell invocation
- Route ecosystem and simple runner production adapters through the seam:
  - npm / bun / vendor / cargo process helpers used by production `*Ops`
  - ebuild manifest runner, egencache runner, portageq runner as product exposes them
- Provide `mk*Ops` / production wiring so Unit tests can supply scripted `CommandRunner` fakes
- Add **Unit** tests that exercise production adapter paths with scripted process results (success and controlled failure)
- Keep phase-one coverage success floor-free; no live network or live tool requirement in the gate

### Non-goals

- SSH/GPG production process residual (wave `process-agents-residual`)
- Fake-HTTP duals for GitHub/npm registry/go.mod (wave `registry-http-fakes`)
- Registry HTTP half of `Update.Npm.Cache` (owned by registry-http-fakes)
- Apply/Check/Plan Integration branch residual (wave `apply-branch-residual`)
- Git process migration (already well covered via temp repos)
- Full interactive TTY/askpass SSH
- Numeric floors / scoring cold `app/Main`

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `test-coverage`: Require Unit coverage of ecosystem/runner production process adapters via injectable CommandRunner fakes; remain floor-free

## Impact

- **Library:** new internal process module; refactors in `Update.Npm.Cache`, `Update.Bun.Cache`, `Update.Go.Vendor`, `Update.Cargo.Crates`, `Update.Apply.Env`, `Update.Md5Cache`, `Update.Runtime.Ceilings` / `Update.Deps.Plan` portageq production as applicable
- **Cabal:** prefer `other-modules` for Process; minimal public exports; no casual `exposed-modules` growth
- **Tests:** Unit cases in ecosystem/apply-adjacent test modules with scripted runners
- **Quality gates:** `hk check` / `./scripts/coverage` remain floor-free
- **Program order:** after `coverage-pure-leftovers`; before or parallelizable with late `registry-http-fakes`
