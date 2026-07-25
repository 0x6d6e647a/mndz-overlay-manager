## Why

After the HPC coverage program and five raise-coverage waves, Overall product coverage sits near ~65% expressions. Easy pure and thin-IO library surfaces (config load messages, CLI parser residual, logging bootstrap, overlay validation/version edges, auth token resolution, and `Update.Types` helpers) still leave yellow HPC residual while later waves tackle ProcessOps and Fake-HTTP. Harvesting those leftovers under Unit first raises coverage with minimal product risk and keeps apply contexts small before larger seams.

## What Changes

- Add **Unit**-isolation tests that execute remaining cold pure / thin-IO product library paths (not reimplementations), including:
  - Config load path defaults and `ConfigError` message coverage
  - CLI parser residual (verbosity parse edges, work-command help infos, `showTopLevelHelpExit1` where practical)
  - Logging bootstrap (`mkLogger`, hold/flush edges as product exposes them)
  - Overlay validation failure arms and version parse/render residual edges
  - GitHub token resolution edges (`resolveGitHubToken` / `resolveGitHubTokenWith`)
  - `Update.Types` helpers (`techniqueNeedsAssets`, `ecosystemIs*`, `splitPackageKey` success and `Nothing` arms)
- Keep tests inside existing `test/Test/*` modules (or small focused additions); no new isolation level
- Keep phase-one coverage gate semantics: tests pass + reports produce; **no** numeric floors or ratchet in this change
- No production behavior changes unless a tiny pure bug is revealed while writing tests (fix only if discovered)

### Non-goals

- ProcessOps / CommandRunner seams (later wave)
- Fake-HTTP duals for GitHub, npm registry, or go.mod (later wave)
- SSH/GPG production process adapters (later wave)
- Apply/Check/Plan/Materialize Integration branch residual (later wave)
- Scoring or instrumenting cold `app/Main` into the HPC product denominator
- Numeric coverage floors, baselines, or `hk` percentage failure
- Live network, live agents, or PATH-optional tool tests for the gate

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `test-coverage`: Require Unit tests that exercise the pure/thin-IO leftover surfaces listed above, without introducing floors

## Impact

- **Tests:** primarily `test/Test/Config.hs`, `test/Test/CLI.hs`, `test/Test/Overlay.hs`, `test/Test/Assets.hs` (auth), and/or a small dedicated Unit group if cleaner; `test/Main.hs` only if a new test module is registered
- **Product library:** no intentional API changes; modules heated by reference only (`Config.Loader`, `CLI.Parser`, `Logging.Bootstrap`, `Overlay.Validation`, `Overlay.Version`, `Update.Auth`, `Update.Types`)
- **Docs:** none required unless CONTRIBUTING test filter examples need a new module name
- **Quality gates:** still `hk check` / `./scripts/coverage`; success remains floor-free
- **Follow-on program (out of scope here):** process-command-runner → registry-http-fakes → process-agents-residual → apply-branch-residual
