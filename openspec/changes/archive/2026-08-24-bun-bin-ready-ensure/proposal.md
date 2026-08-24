## Why

Full-path `update` bind-mounts the overlay worktree and `emerge`s `dev-lang/bun-bin::mndz` into the materialize image. A half-finished GitMv (ebuild already at the remote PV, Manifest still on the old DIST names) makes that emerge fail Portage checksum verification (`VERIFY FAILED` / empty `Got:`). The same run then EQ-skips bun-bin as “already at latest,” so waves never wait and Docker sees an unemergeable tree. When bun-bin *does* need a real bump, the first ensure still uses **on-disk** bun floors and withheld Bun consumers, so the image can be built against 1.3.14 while ralph’s post-commit plan needed 1.4.0 (second ensure). `update` should refuse leftover overlay dirt, make bun-bin emergeable **before** `docker build`, and plan Bun consumers against the **known** bun-bin remote at t0 so one image matches that plan.

## What Changes

- **Start-of-run overlay dirty preflight:** `git status --porcelain` on selected package directories **and** overlay atoms this ensure will emerge (`dev-lang/bun-bin` even on `update dolt`). Untracked and deleted count. Dirty → hard-fail, no mutate, no `docker build`. Operator restores or finishes the tree. No GitMv auto-resume.
- **Weaker A:** when this ensure’s recipe will `emerge dev-lang/bun-bin::mndz`, do not start `docker build` until on-disk bun-bin has the ebuild PV being emerged, Manifest DIST hashes for that PV, and package `egencache`. Independent GitMv (`grok-build-bin`, `deno-bin`) still overlaps ensure.
- **t0 hypo working plan:** when bun-bin is **selected and needs work**, selected Bun consumers are planned against **hypothetical bun-bin-at-remote ceilings** (same construction as today’s unselected plan-delta). That plan is what classify, floors, and apply use. No mid-run rediscovery / disk re-plan after bun-bin commits. Unselected bun-bin: plan-delta refuse / fail-closed **unchanged**.
- **One ensure** at the hypo bun floor (union previous `image.json` as today). First ensure’s needed floors include full-path units of hypo-planned consumers even while those consumers are withheld from mutate.
- **Safety assert:** before a hypo-planned consumer’s overlay write, planned bun-bin PV must equal overlay bun-bin. Mismatch → hard-fail that consumer, no mutation; error names both packages and both PVs.
- **Commit order / GPG:** bun-bin still GitMv-renames and regenerates Manifest/`egencache` before docker. When this run **will ensure**, delay bun-bin’s signed overlay commit until ensure **finishes (success or fail)** so pinentry is the “image build done” cue; GitMv-only bun-bin still commits after `egencache`. Then admit Bun consumers. **No split** of ralph materialize vs overlay write. **No** end-of-`update` commit barrier; other packages keep commit-on-unit-success.
- **Check-cache option A:** do not store a deps plan computed under hypo ceilings. After bun-bin is on HEAD, later store against disk fingerprints as today.
- **README** operator `update` / waves / ensure text matches the new sequence.

**Not BREAKING** for overlay consumers. **Operator-visible:** `update` may refuse a dirty overlay; bun-bin `ebuild manifest` runs before a bun-layer image build; GPG for bun-bin (when ensure ran) happens after docker; ralph is not re-planned from disk in the same run.

### Non-goals

- Holding **all** overlay commits until ensure ends (`grok-build-bin` may still pinentry during docker)
- Changing `outdated` to print hypo ceilings (still on-disk + blocked-on)
- Whole-overlay dirty (unrelated WIP must not fail the run)
- GitMv auto-resume / healing half-renames
- Binding Docker overlay context to git HEAD (keep worktree bind)
- Keying check-cache by hypo PV or `image.json`
- Splitting ralph materialize from overlay write
- Deferring every overlay commit to the end of `update`
- Manifest-file GPG (`ebuild manifest` does not sign Manifest)

## Capabilities

### New Capabilities

- _(none)_

### Modified Capabilities

- `overlay-apply-waves`: Selected bun-bin that needs work → Bun consumers use hypo-at-remote as the **working** plan (not on-disk, not a later disk re-plan); still withhold mutate until bun-bin signed commit; hard-fail consumers if bun-bin hard-fails or safety assert fails
- `ensure-materialize-image`: Docker that emerges overlay bun-bin waits on bun-bin Manifest+egencache; t0 floors include withheld hypo-planned full-path Bun units; one ensure (no second ensure solely because bun-bin committed)
- `update-command`: Dirty preflight; hypo plan at t0; ensure after bun-bin file work; bun-bin commit after ensure attempt; then consumers; no consumer disk re-plan
- `update-apply`: Dirty preflight before mutation; bun-bin commit delayed until ensure finishes when ensure ran; consumer overlay write gated on safety assert
- `check-cache`: Deps plans computed under hypo overlay ceilings SHALL NOT be stored
- `project-docs`: README `update` / waves / materialize paragraphs match dirty preflight, hypo plan, ensure-after-manifest, GPG after image build
- `cli-activity`: Status/progress for dirty preflight, waiting on bun-bin Manifest before ensure, and bun-bin commit after ensure

## Impact

- **Code:** `Update.Spine` (dirty preflight; t0 hypo plan + classify withheld Bun consumers for floors; ensure after bun-bin file work; bun-bin commit sequencing); `Update.OverlayWaves` / apply admit pool (working plan is hypo; no `WavePrepare` disk re-plan for this edge); `Update.Apply.GitMv` (commit delay when ensure ran); `Update.Materialize.Floors` / `Ensure` (bun floor from hypo; recipe still bind worktree); `Update.CheckCache` (skip store for hypo plans); `Update.Git.pathsDirty`
- **Tests:** Dirty preflight (untracked/deleted bun-bin, unselected bun-bin + `update dolt`); ensure does not start until Manifest DIST matches PV; hypo plan classify includes ralph floors at t0; no second ensure after bun-bin commit; check-cache does not store hypo plan; safety-assert copy; bun-bin commit after failed ensure still lands. No live Gentoo `docker build` in `hk check`
- **Docs:** `README.md` (project-docs)
- **Operator:** Clean overlay required; first bun-layer image waits on bun-bin distfile fetches; pinentry after docker when ensure ran
