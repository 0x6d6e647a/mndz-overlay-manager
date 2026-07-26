## 1. Project Cabal parallelism

- [x] 1.1 Add `jobs: $ncpus` and `semaphore: True` to `cabal.project` (with brief comments)
- [x] 1.2 Add `-j --semaphore` to `cabal install` in `scripts/install-dev-tools`

## 2. Documentation and specs

- [x] 2.1 Document multi-core defaults, overrides, and install-dev-tools exception in `CONTRIBUTING.md`
- [x] 2.2 Keep OpenSpec delta specs for `git-hooks-quality-gates` and `project-docs` aligned with implementation

## 3. Verification

- [x] 3.1 Confirm a project `cabal build` / plan run inherits jobs (e.g. verbose output or config effective)
- [x] 3.2 Run `hk check` (or full quality pipeline) green
