## Why

Quality-gate and bootstrap Cabal builds often under-use host CPUs: package-level parallelism and GHC module-level parallelism are not configured in the repository. Developers on multi-core machines (including high core-count hosts) wait longer than necessary for `cabal build`, coverage tests, and `./scripts/install-dev-tools`.

## What Changes

- Enable multi-core Cabal builds project-wide via `cabal.project`: `jobs: $ncpus` and `semaphore: True` (Cabal jobserver + GHC module parallelism without oversubscription).
- Pass explicit `-j --semaphore` on `./scripts/install-dev-tools` `cabal install` (that path uses `--ignore-project` and would otherwise skip project settings).
- Document host-CPU parallelism, override knobs (`-jN`, `cabal.project.local`), and the install-dev-tools exception in `CONTRIBUTING.md`.
- Encode the policy in OpenSpec deltas for `git-hooks-quality-gates` and `project-docs`.

## Non-goals

- No product CLI / operator behavior changes.
- No change to hk step ordering, coverage triple-run structure, or HIE / analyzer semantics.
- No hard job cap for high core-count machines (full `$ncpus`; per-machine override remains optional via `cabal.project.local`).
- No CI configuration (none in-repo today).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `git-hooks-quality-gates`: Require project Cabal config to enable host-CPU job count and semaphore-based GHC parallelism for project builds; require install-dev-tools to pass equivalent flags when ignoring the project file.
- `project-docs`: Require CONTRIBUTING to document multi-core Cabal build policy and overrides.

## Impact

- `cabal.project` — add `jobs` and `semaphore`
- `scripts/install-dev-tools` — add `-j --semaphore` to `cabal install`
- `CONTRIBUTING.md` — contributor note on parallelism
- OpenSpec deltas for the two capabilities above
- Runtime: higher peak CPU/RAM during builds on large machines; functional outcomes unchanged
