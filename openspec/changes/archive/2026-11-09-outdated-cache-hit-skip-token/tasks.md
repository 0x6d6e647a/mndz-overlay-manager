# Tasks

## 1. Outdated live-GitHub decision

- [x] 1.1 Extract the "will this check run the hypothetical consumer plan?" branch out of `applyOverlayBlockIndication` into one helper, and call that helper from the check path. Verify `just test CheckPlan` passes, including equal ceilings, hypothetical lane lines, and a selected provider that is not GitMv-outdated.
- [x] 1.2 Add an outdated versus update mode to `needsLiveGitHubApi`. Outdated mode treats a usable deps-plan hit as not live even when the plan still needs work, and treats a miss, `--refresh`, a cold provider latest, or a helper-true hypothetical plan as live. Update mode keeps today's answer, including live when a cached plan still needs work. Pass the outdated mode from `runOutdated` and the update mode from `runUpdate`. Do not change `update`'s plan-phase hypothetical path. Add `GitHubResilience` cases for those mode answers and verify `just test GitHubResilience` passes.

## 2. Operator docs

- [x] 2.1 Update the README GitHub-token paragraphs so `outdated` does not prompt when every `api.github.com` read is a valid check-cache hit, including when a cached plan still needs work, and so `update` still prompts when it will look up or publish an assets release. Verify those two statements are present in `README.md`.

## 3. Gate

- [x] 3.1 Validate this change with `openspec validate outdated-cache-hit-skip-token --type change --strict` and confirm it passes.
- [x] 3.2 Run `just check` and confirm the full gate passes.

## Workflow follow-up

- Archive the change after the tasks above are done and the gate is green.
- Sync the delta specs into `openspec/specs/` as part of that archive.
