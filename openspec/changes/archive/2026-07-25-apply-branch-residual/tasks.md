## 1. applyOverlay orchestration

- [x] 1.1 Integration: multi-package `applyOverlay` with jobs=1 (soft/hard outcome mix as product allows)
- [x] 1.2 Integration: multi-package `applyOverlay` with jobs>1 (concurrency/lock path)
- [x] 1.3 Assert fold/exit behavior for hard-fail mix without requiring live tools

## 2. contentFix matrix

- [x] 2.1 Integration: contentFix Go (on-disk ebuild/Manifest) + content-only reusable flag/Ok path as product defines
- [x] 2.2 Integration: contentFix Npm similarly
- [x] 2.3 Integration: contentFix Bun
- [x] 2.4 Integration: contentFix Cargo

## 3. GitMv, ceilings, materialize residual

- [x] 3.1 Unit/Integration: GitMv residual soft/hard/dirty/error arms still yellow under HPC
- [x] 3.2 Integration/Unit: runtime ceiling discover residual with empty caches / fake portageq (not production process rewrite)
- [x] 3.3 Integration: Materialize residual arms (plan-fail, prune, missing token/assets, sidecar/verify) still yellow after prior waves

## 4. Quality gate

- [x] 4.1 `./scripts/coverage` green (floor-free)
- [x] 4.2 `hk check` green
- [x] 4.3 Confirm tasks 1.2 and 2.3–2.4 completed (T8/T9 A+B) before marking change done
