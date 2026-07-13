## Context

The repository is a Cabal Haskell project (GHC 9.10.3) with library, executable, and test suite. There is no `hk.pkl`, no project-local quality tools, and only sample git hooks. Exploration settled on **hk** as the hook runner and **Cabal** as the sole tool provider (no mise), with tools installed into a project-local bin directory (Option B) under a **strict** missing-tool policy.

Quality priority is correctness over speed: compile/test and HIE-based analyzers are blocking. Cabal incremental builds make repeated clean-tree runs cheap once artifacts exist.

## Goals / Non-Goals

**Goals:**

- Block commits (and `hk check`) unless format, tests, hlint, stan, and weeder all pass.
- Pin and install ormolu, hlint, stan, and weeder via Cabal into `.tools/bin`.
- Fail loudly with a bootstrap message when a required tool binary is missing (no auto-install).
- Generate HIE files as part of normal project builds so stan/weeder are correct under the project GHC.
- Provide a single documented bootstrap path: install tools script + `hk install`.

**Non-Goals:**

- mise, pre-commit, lefthook, or other hook managers.
- Auto-installing tools inside hooks.
- Non-blocking / advisory-only stan or weeder.
- CI workflow wiring (may reuse `hk check` later; not required here).
- Automating GHC upgrades or rewriting dependency bounds (`allow-newer` is out of scope).
- Changing application CLI or library behavior.

## Decisions

### D1: hk as orchestrator, Cabal as tool provider

- **Choice:** System-installed `hk` reads `hk.pkl`; tools are not managed by mise.
- **Why:** hk is already installed; it handles stash/restage, fix steps, and parallel-friendly step graphs. Cabal ensures weeder/stan match project GHC (HIE version lock).
- **Alternatives:** pre-commit / lefthook (no better Haskell story); mise for ormolu/hlint only (incomplete for stan/weeder); hand-rolled hooks (reimplement hk features).

### D2: Option B — `cabal install` → `.tools/bin`

- **Choice:** Pin tool versions with `constraints:` in `cabal.project`. `scripts/install-dev-tools` runs `cabal install` for ormolu, hlint, stan, weeder into `$PWD/.tools/bin` with `--install-method=copy` and `--overwrite-policy=always`.
- **Why:** Keeps the app dependency plan separate from tool dep trees; hooks invoke plain binaries (fast, simple); same compiler as the project when run from the project tree.
- **Alternatives:** A (`extra-packages` / `list-bin`) — more “in cabal” but couples plans and adds hook latency; C (user `~/.local/bin` / package-env) — weak isolation and easy weeder/GHC mismatch.

### D3: Strict missing-tool policy

- **Choice:** If any required binary under `.tools/bin` is missing or not executable, the step (or a dedicated preflight step) fails with instructions to run `scripts/install-dev-tools`.
- **Why:** Avoids hidden network/build work during commit; agents and humans get an explicit, fixable error.
- **Alternatives:** Auto-install on miss (slow, surprising); soft-skip missing tools (undermines quality gates).

### D4: Blocking pipeline order

```
1. ormolu   (fix on pre-commit / hk fix; check on pure check paths as appropriate)
2. cabal test all   (build + tests; blocking; produces HIE when flags set)
3. hlint
4. stan
5. weeder
```

- **Why:** Format first so later diagnostics match final layout; `cabal test` is the compile+test gate and regenerates HIE when sources change; analyzers run on a tree that already typechecks and passes tests. Incremental `cabal test` is cheap when up to date.
- **Alternatives:** Fast-only pre-commit (rejected: quality-first); separate pre-push for stan/weeder (rejected: user wants full blocking suite).

### D5: HIE configuration

- **Choice:** Enable `-fwrite-ide-info` and a stable `-hiedir=.hie` (or project-equivalent) for components analyzed by stan/weeder via common stanza and/or `cabal.project` program options. Gitignore the HIE output directory.
- **Why:** stan and weeder require HIE; a fixed directory simplifies stan invocation; weeder must read HIE from the same GHC that built the tools.

### D6: Tool invocation in hooks

- **Choice:** Prefer explicit `.tools/bin/<tool>` paths (or a single PATH prefix limited to that directory) in `hk.pkl` steps—not bare names from the ambient PATH.
- **Why:** Enforces project-local tools and avoids accidental global binaries.

### D7: Supporting config files

- **weeder.toml:** Define roots (e.g. executable/test mains, `Paths_*`) so library exports used only from mains are not false weeds.
- **.hlint.yaml (optional):** Only if default hlint is too noisy; start minimal and tighten as needed.
- **No mise.toml** for this workflow.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Tool pins fail to build on GHC 9.10.3 | Spike during implement: solve/install each tool; pin versions that work; document pins in `cabal.project`. |
| First `install-dev-tools` is slow | Expected one-time (and after pin bumps); not run from hooks. |
| Stale `.tools/bin` after constraint bumps | Strict fail still runs old binaries until reinstall; document “re-run install after pin changes”; optional version check later. |
| weeder/stan noise on first enable | Tune `weeder.toml` / stan config; fix real issues or add justified ignores; keep gates blocking once baseline is clean. |
| weeder GHC mismatch | Always install tools with project Cabal/GHC into `.tools/bin`; never document global weeder. |
| Hook latency on dirty trees | Accepted for quality; clean trees stay near-idempotent via Cabal incremental builds. |
| `cabal test` needs network on cold cache | Developer machine responsibility; freeze optional later. |

## Migration Plan

1. Add `cabal.project` constraints, HIE-related options, gitignore entries.
2. Add `scripts/install-dev-tools` and run it once to populate `.tools/bin`.
3. Add `weeder.toml` (and hlint/stan config if needed); clear baseline findings.
4. Add `hk.pkl` with the ordered steps and strict preflight.
5. Run `hk install` (local or rely on existing global install).
6. Verify: `hk check` passes on a clean tree; missing-tool path fails as expected; a deliberate format/test failure blocks.

**Rollback:** Remove or rename `hk.pkl` / uninstall hooks; delete `.tools/` and script; revert cabal/gitignore. No production runtime impact.

## Open Questions

- Exact tool version pins that solve cleanly on GHC 9.10.3 (resolve at implementation time).
- Whether hlint uses check-only or also refactor-based fix (default: check-only unless refactor proves safe).
- Whether README vs short comment in `scripts/install-dev-tools` is enough for bootstrap docs (prefer script header + minimal README note if a README exists or is added).
