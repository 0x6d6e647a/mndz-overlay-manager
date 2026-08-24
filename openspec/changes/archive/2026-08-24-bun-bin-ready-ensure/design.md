## Context

See `proposal.md` for motivation. Today `Update.Spine` classifies **admitted** packages only for t0 ensure floors, withholds Bun consumers until bun-bin’s signed commit, then `WavePrepare` rediscovers overlay bun-bin ceilings from disk and re-plans. `Update.Apply.GitMv` always `commit -S` immediately after `egencache`. Ensure bind-mounts the overlay **worktree** and may `docker build` in parallel with bun-bin GitMv, so Portage can emerge a renamed ebuild against a stale Manifest. `pathsDirty` already treats porcelain ` D` / `??` as dirty but only runs on the GitMv **outdated** (`LT`) path, so a leftover rename EQ-skips.

Hypo ceilings for **unselected** bun-bin already exist (`planDepsPackageWithCeilings` / plan-delta). This change uses that plan as the working plan when bun-bin **is** selected and needs work.

## Goals / Non-Goals

**Goals:**

- Refuse leftover overlay dirt before mutate/docker (scoped pathspecs).
- Make overlay bun-bin emergeable (Manifest + egencache) before a bun-layer `docker build`.
- Plan/classify Bun consumers at t0 against bun-bin remote; one ensure; no disk re-plan.
- Delay only bun-bin’s overlay commit until ensure **attempt** finishes when ensure ran.
- Do not cache hypo-ceiling deps plans.

**Non-Goals:**

- Holding all overlay commits until ensure ends; `outdated` hypo display; whole-overlay dirty; GitMv auto-resume; HEAD bind; check-cache ceiling-PV field; splitting ralph materialize vs overlay write.

## Decisions

### 1. Dirty preflight is spine-level, not GitMv EQ-resume

`git status --porcelain --` on selected package dirs plus overlay atoms the **recipe will emerge** (`dev-lang/bun-bin` when `TkBun` is in the install list). Run after plan (so we know whether ensure will emerge bun-bin) and before mutation/`docker build`.

**Alternatives:** GitMv Manifest-vs-PV adequacy / auto-resume (operator rejected; dirt is theirs). Whole-overlay dirty (blocks unrelated WIP). Selected-only (misses `update dolt` with dirty bun-bin).

### 2. Weaker A: files before docker, not commit

`applyGitMv` splits: rename + `ebuild … manifest` + `egencache` can complete and signal “emergeable”; `commit -S` is a later step when ensure ran. Spine starts ensure only after that signal for bun-bin. Worktree bind unchanged.

**Alternatives:** Stronger A (wait for `commit -S` before docker) — extra pinentry wait, no Portage benefit. Bind HEAD — would require commit before docker.

### 3. t0 hypo is the working plan; no `WavePrepare` disk re-plan

When bun-bin is selected and `comparePV` is `LT`, Bun consumers call the existing hypothetical-ceiling planner (same as plan-delta) and **keep** that `RuntimeLanePlan`. Classify those consumers at t0 so `neededFloorsFromClassified` includes their full-path bun floor. After bun-bin `ApplySuccess`, admit using that plan; assert overlay bun-bin newest PV equals the planned remote before overlay write.

**Alternatives:** Keep disk re-plan (second ensure, races dirty tree). Plan from worktree after Manifest (couples consumers to uncommitted dirt if commit later fails).

### 4. bun-bin `commit -S` after ensure **attempt**

When `t0FullKeys` is non-empty (ensure will run), do not call overlay commit at the end of bun-bin file work; after `usdEnsureImage` returns (Left or Right), commit bun-bin if file work succeeded, then admit consumers. GitMv-only: existing immediate commit.

**Why attempt not success only:** a failed docker must not leave bun-bin renamed+uncommitted (next dirty preflight would hard-fail a valid GitMv).

**Alternatives:** Immediate commit overlapping docker (pinentry mid-build). Commit only on ensure success (dirt on docker fail). All-commits-after-ensure (leftover `gpg-after-ensure`).

### 5. Check-cache option A

`storeDeps` is skipped when the plan was computed with hypothetical provider ceilings. After bun-bin is on HEAD, a later ralph success stores against disk fingerprints as today.

**Alternatives:** New `overlay_provider_ceiling_pv` field (C/C′) or PV-only match (D). Dirty preflight makes the “retry still 1.3.14 + same hypo” hit rare; A avoids schema work and stale hits.

### 6. Progress

Extend t0 sequential/apply labels: dirty preflight step; bun-bin Manifest status; commit after ensure. Ralph remains “waiting on bun-bin” through docker until that commit. Do not add a second apply panel.

## Risks / Trade-offs

- **[Risk] Ctrl-C after rename, before Manifest** → next run dirty-preflight fails. **Mitigation:** operator restores; documented in README. No auto-heal.
- **[Risk] `grok-build-bin` pinentry during docker** → accepted leftover (`gpg-after-ensure`).
- **[Risk] Hypo plan stale vs landed PV** → safety assert hard-fails ralph; bun-bin may still have committed.
- **[Risk] Half-applied bun-bin during docker (uncommitted)** → recipe bind sees worktree; weaker A requires Manifest first; commit after ensure. Dirty preflight on **next** run.
- **[Trade-off] Extra ralph network on hypo runs** (no cache) → once per bun-bin bump; cheaper than wrong cache hits.

## Migration Plan

No schema/config migration. First `update` after upgrade: restore leftover bun-bin/grok-build-bin dirt if present, then run as usual. Rollback is revert of this change; overlay commits already made stay.

## Open Questions

None. Leftovers (`gpg-after-ensure`, `outdated-hypo-bun-ceilings`) are out of this change; see wiki `bun-bin-ready-ensure-leftovers-handoff.md`.
