## Context

Cabal has two independent parallelism layers:

1. **Package/component jobs** (`jobs` / `-j`) — how many packages Cabal builds at once.
2. **Module jobs inside GHC** — by default Cabal still runs each GHC with serial modules (`-j1` per package) to avoid oversubscription.

Day-to-day project rebuilds are dominated by one large local library (~50 modules) plus thin exe/test components. Package-level `-j` alone does little once dependencies are warm. GHC 9.8+ and cabal-install 3.12+ support `--semaphore` / `semaphore: True`: Cabal acts as a jobserver so GHC can take extra cores for modules without oversubscribing.

Today the repo invokes bare `cabal build all` / `cabal test all` in hk and coverage scripts, and `cabal install ... --ignore-project` in install-dev-tools, with no project-level `jobs` or `semaphore`.

## Goals / Non-Goals

**Goals:**

- Project Cabal builds (hooks, coverage, local `cabal build`/`test`) use host CPU count and semaphore coordination by default.
- install-dev-tools gets the same class of parallelism despite `--ignore-project`.
- Portable across machines via `$ncpus` (laptop through high core-count hosts).
- Document policy and overrides in CONTRIBUTING; encode in OpenSpec.

**Non-Goals:**

- Parallelizing hk pipeline steps (ormolu → build → coverage → analyzers stay ordered).
- Changing coverage’s three sequential tasty runs.
- Hard-coding a job cap for Threadripper-class machines.
- Wiring CI (none present).

## Decisions

### 1. Project-wide defaults in `cabal.project` (Option A)

**Choice:** Add:

```cabal
jobs: $ncpus
semaphore: True
```

**Why over flag-only in hk/scripts:** One source of truth; every project-aware `cabal` invocation inherits it (including bare CONTRIBUTING examples). `$ncpus` is a Cabal token expanded at runtime to host logical CPU count — not a shell variable.

**Alternatives:** Explicit `-j --semaphore` only in hk.pkl/coverage (easy to miss a site); fixed `jobs: 8` (wrong on both small and large hosts).

### 2. install-dev-tools explicit flags (A2)

**Choice:** Add `-j --semaphore` to the `cabal install` line.

**Why:** Script uses `--ignore-project` so project fields do not apply. Cold tool installs (ormolu/hlint/stan/weeder + ghc-lib-parser) are the fattest multi-package builds in the workflow.

### 3. No default job cap

**Choice:** Leave full `$ncpus`. Overrides: CLI `-jN` or gitignored `cabal.project.local`.

**Why:** Matches developer intent on high core-count machines; RAM risk is operator-managed, not a silent under-use of hardware.

### 4. Spec + CONTRIBUTING, not README

**Choice:** Delta `git-hooks-quality-gates` and `project-docs`; update CONTRIBUTING only (quality bootstrap / pipeline policy). README is operator-facing and does not own the quality pipeline.

### 5. Toolchain assumption

**Choice:** Require GHC ≥ 9.8 and cabal-install ≥ 3.12 for semaphore (project already targets GHC 9.10.x). Semaphore ignored or unsupported on older toolchains is out of scope; CONTRIBUTING already states GHC 9.10.x.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| High peak RAM with many concurrent GHC processes | Document override via `-jN` / `cabal.project.local`; no hard cap in repo |
| Semaphore bugs or unexpected interaction | Feature is opt-in in Cabal for this reason; project pins modern toolchain |
| install-dev-tools flags drift from cabal.project | Spec requires explicit flags when ignoring project; CONTRIBUTING notes the exception |
| Single-module rebuild still single-core | Expected; critical path is one module — no design change needed |

## Migration Plan

1. Edit `cabal.project` and `scripts/install-dev-tools`.
2. Update CONTRIBUTING and OpenSpec deltas.
3. Smoke: `cabal build all -v2` shows parallel/semaphore activity; `hk check` still green.
4. Rollback: remove the two cabal.project lines and install-dev-tools flags.

## Open Questions

None — resolved in exploration:

1. install-dev-tools → A2 (explicit flags).
2. CONTRIBUTING docs → yes.
3. OpenSpec deltas → do not skip.
4. Full `$ncpus` on large hosts → yes.
5. CI → none in-repo; same `$ncpus` applies if CI appears later.
