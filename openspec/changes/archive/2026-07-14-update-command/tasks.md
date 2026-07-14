## 1. Types and hardcoded policy

- [x] 1.1 Extend `Update.Types` with `UpdateTechnique` (`GitMvAndManifest` | `Unsupported` reason) and `PackagePolicy` (source + technique)
- [x] 1.2 Expand `Update.Hardcoded` to a full policy map for all twelve mndz overlay packages (sources + techniques per design table)
- [x] 1.3 Add pure lookup helpers and hand-rolled tests for policy classification (GitMv vs Unsupported, unmapped)

## 2. Remove inference

- [x] 2.1 Change `Update.Resolve` to hardcoded policy/source lookup only
- [x] 2.2 Delete `Update.Infer` and remove it from the cabal exposed-modules list
- [x] 2.3 Update or remove inference-only tests; ensure `outdated` path still works with map-only sources
- [x] 2.4 Run weeder-oriented cleanup so no dead inference exports remain

## 3. Preflight and target resolution

- [x] 3.1 Implement action-scoped PATH preflight (`git`, `ebuild`, `gpg` required only for `update`)
- [x] 3.2 Implement package target parsing: zero args = all; `cat/pkg`; bare `pkg` with ambiguity error
- [x] 3.3 Add hand-rolled tests for target resolution and preflight missing-tool behavior (injectable path search if needed)

## 4. Apply: dirty, rename, ebuild manifest

- [x] 4.1 Implement git dirty check for newest ebuild + Manifest paths (overlay must be a git worktree)
- [x] 4.2 Implement ebuild rename to remote PV (no invented `-rN`; leave other versions in place)
- [x] 4.3 Implement `ebuild ./<new>.ebuild manifest` with cwd = package directory; capture stderr on failure
- [x] 4.4 On failure after rename, emit hard error plus dirty/half-applied warning
- [x] 4.5 Add unit tests with mocked process/git status for dirty, rename planning, and failure paths

## 5. Parallel phase and signed commits

- [x] 5.1 Orchestrate phase 1: concurrent per-package check → dirty → rename → manifest; collect outcomes
- [x] 5.2 Implement phase 2 barrier: if any success, sorted-by-key serial `git add` (pathspecs only) + `git commit -S -m "cat/pkg: ver"`
- [x] 5.3 Ensure mutual exclusion around git index ops; no unsigned fallback; skip commit phase when zero successes
- [x] 5.4 Soft-skip unmapped, unsupported, and not-outdated with warnings; hard-fail dirty/ebuild/git/sign/fetch; continue siblings
- [x] 5.5 Add tests for outcome aggregation and exit-code folding (soft-only vs any hard fail)

## 6. CLI wiring

- [x] 6.1 Add `update` subcommand to `CLI.Parser` with zero-or-more package arguments
- [x] 6.2 Wire `Main` spine: config → path → validate → discover → preflight → update pipeline
- [x] 6.3 Print one stdout success line per committed update (`cat/pkg vLOCAL -> vREMOTE`); log soft/hard outcomes
- [x] 6.4 Ensure help/`--help` lists `update`

## 7. Dependencies and quality gate

- [x] 7.1 Add any needed library deps (`async`, `process`/`typed-process`, etc.) to the cabal file
- [x] 7.2 Run `hk fix` / format; `cabal test all`; full `hk check` until green
- [x] 7.3 Optional manual smoke: `update` dry path against real overlay (not required for CI)
