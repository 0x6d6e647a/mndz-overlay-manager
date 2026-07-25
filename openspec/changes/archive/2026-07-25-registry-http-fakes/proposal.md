## Why

`Update.GitHub` (~7% expr), npm registry list/engines paths, and `Update.Go.ModFetch` production HTTP remain cold because Check/Plan inject higher-level fakes and never call production HTTP clients. Release-style `*HttpLbs` + `Test.HttpFake` already prove the pattern. Wave 3 heats registry/API HTTP under Unit without live network. Process/builder halves of npm/bun stay in process waves (T7-A).

## What Changes

- Add public **HttpLbs duals** (Release-style) for GitHub fetch/list, npm registry list/engines, and go.mod fetch as product exposes them (T5-A)
- Unit Fake-HTTP matrices: success, auth headers, decode/HTTP/network errors
- **GitHub list:** single-page + error/fallback matrix **and** multi-page pagination (T6 A+B) in this change
- **Npm.Cache:** registry HTTP only in this change (T7-A); not pack/install/tar process
- Keep Manager thin wrappers acceptable if duals heat the bulk of residual
- Floor-free coverage gate; no live GitHub/npm

### Non-goals

- ProcessOps / production process adapters
- npm/bun/cargo builder process bodies
- Apply Integration residual
- Floors, cold Main scoring
- Live network in the gate

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `test-coverage`: Require Unit Fake-HTTP coverage for GitHub, npm registry, and go.mod production HTTP paths; floor-free

## Impact

- **Library:** `Update.GitHub`, `Update.Npm.Cache` (registry surfaces), `Update.Go.ModFetch`; possibly thin re-exports / duals pattern from `Update.Http` / `Update.Assets.Release`
- **Tests:** Unit modules + `Test.HttpFake` (or extension)
- **Program order:** after or parallelizable with late `process-command-runner`; does not depend on SSH agents wave
