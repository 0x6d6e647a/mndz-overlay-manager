## 1. Dirty preflight

- [x] 1.1 Spine-level overlay dirty check: `git status --porcelain --` on selected package dirs plus overlay atoms this ensure will emerge (`dev-lang/bun-bin` when the recipe has `TkBun`), including untracked/deleted; fail before mutate/`docker build` with a message naming a dirty path or package
- [x] 1.2 Tests: leftover ` D`/`??` bun-bin fails `update dolt` without ensure; dirty selected package fails; overlay-root-only dirt (e.g. README) does not fail; clean tree proceeds

## 2. bun-bin file work before docker; commit after ensure

- [x] 2.1 Split GitMv file work (rename, `ebuild … manifest`, package `egencache`) from signed commit so bun-bin can become emergeable without committing
- [x] 2.2 When this run will ensure and the recipe emerges overlay bun-bin, do not start `docker build` until bun-bin file work succeeded; independent GitMv still overlaps ensure
- [x] 2.3 When ensure ran, create bun-bin `commit -S` after ensure **finishes** (success or fail) if file work succeeded; GitMv-only bun-bin still commits immediately after egencache
- [x] 2.4 Tests: ensure fake does not start until Manifest-ready signal; grok-build-bin may run during fake ensure; bun-bin commit invoked after failed ensure; GitMv-only path still commits without ensure

## 3. Hypothetical working plan and one ensure

- [x] 3.1 When bun-bin is selected and needs work, plan selected Bun consumers with existing hypothetical-at-remote ceilings as the **working** plan; classify those consumers at t0 so floors include their full-path bun PV
- [x] 3.2 t0 `neededFloorsFromClassified` includes withheld hypo-planned Bun full-path units; recipe bun-bin atom uses that PV
- [x] 3.3 After bun-bin signed commit, admit consumers on the t0 hypo plan; do **not** rediscover ceilings or re-plan from disk; do **not** `docker build` again solely because bun-bin committed
- [x] 3.4 Before consumer overlay write, assert overlay bun-bin newest non-live PV equals the planned remote; hard-fail with the specified error copy; no mutation
- [x] 3.5 bun-bin apply hard-fail still hard-fails withheld consumers (no on-disk-ceiling apply, no hypo apply)
- [x] 3.6 Tests: ralph working plan is hypo 1.4.0 while disk is 1.3.14; t0 ensure floors include 1.4.0; no second ensure after fake bun-bin commit; safety-assert mismatch hard-fails ralph; provider hard-fail fails ralph; unselected bun-bin plan-delta/fail-closed unchanged

## 4. Check-cache and progress

- [x] 4.1 Do not `storeDeps` when the plan used hypothetical overlay ceilings; after bun-bin is on HEAD, later successful consumer apply may store against disk fingerprints
- [x] 4.2 Test: hypo ralph plan is not stored under bun-bin 1.3.14 fingerprint; a subsequent lookup with disk 1.3.14 does not return a 1.4.0 plan
- [x] 4.3 Progress: dirty-preflight step; bun-bin Manifest status before docker; bun-bin commit visible after ensure; ralph remains waiting on bun-bin through ensure until that commit; one apply panel
- [x] 4.4 Tests for waiting presentation vs hard-fail and no second apply panel

## 5. Docs and quality gate

- [x] 5.1 `README.md`: dirty overlay refuse; hypo plan / no same-run disk re-plan; bun-bin Manifest before bun-layer docker; bun-bin GPG after ensure attempt; keep unselected plan-delta (`project-docs`)
- [x] 5.2 `openspec validate --strict` for this change (and affected capabilities) clean
- [x] 5.3 `hk check` green; HIE rebuilt if modules move; no casual weeder/stan weakening; no `exposed-modules` expansion unless the test-suite requires it
