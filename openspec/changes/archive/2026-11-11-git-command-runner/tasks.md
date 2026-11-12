# Tasks

Phases follow design D1–D5. Each phase ends green under `just check` before the next starts.

## 1. Measure variant (design D2)

- [x] 1.1 Add `TimedInteractive` to `Measure` in `src/Update/Process.hs` with a doc comment ("like `Timed`, plus `interactive: true` on the span"). Verify `just build-release` compiles. If any `Measure` match turns out to be non-exhaustive, `-Wincomplete-patterns` reports it.
- [x] 1.2 Teach `timedRunner` in `src/Metrics/Process.hs` to handle `TimedInteractive` like `Timed`, adding `interactive: true` to the `proc` span's start attributes (`measured` takes the extra attributes). Leave `sessionExecRunner` unchanged. Verify with new `Test.Metrics` cases: a `TimedInteractive` request is wrapped in GNU time with a `.json` time file, its span has `interactive: true` and a `time` object, and a `Timed` request's span has no `interactive` key.
- [x] 1.3 Verify an unresolvable command under `TimedInteractive` runs unwrapped and raises the same `IOException` as without metrics (test with an empty `PATH` in `prEnv`).

## 2. Move Update.Git onto CommandRunner (design D1, D3, D4)

- [x] 2.1 Change `isGitWorkTree`, `pathsDirty`, `gitAddAndSignedCommit`, `gitPush`, and `gitRevParseHead` to take a `CommandRunner` instead of `Metrics`. Build each `ProcessRequest` with `prMeasure = Timed`, except the `git commit -S` and `git push` requests, which use `TimedInteractive`. Pass `prEnv = Just env1` for the signed commit. Remove `gitRead`'s `wallClockProc`. Keep every argument, working directory, and error message identical. Verify the existing real-git tests in `Test.Git`, updated to pass `productionCommandRunner`, still pass.
- [x] 2.2 Make `productionGitOps :: Metrics -> GpgHandle -> GitOps` build `timedRunner m productionCommandRunner` internally, with the same signature as today. Update `Update.Preflight.validateAssetsPath` to pass `productionCommandRunner`. Verify `just build-release` compiles and `Test.Preflight` passes.
- [x] 2.3 Add scripted-fake tests to `Test.Git` with a recording `CommandRunner`:
  - argv and `prMeasure` for each function (`-C` root, `--` and pathspecs, `-m` message, `commit -S`, `push`)
  - the signing environment arriving in `prEnv` for the commit
  - mapping of a non-zero exit and stderr to each `Left` message
  - trimmed stdout for `rev-parse` and the work-tree check
  - `git add` not running when GPG readiness fails

  Verify `just coverage Git` passes and the new cases fail when the argv or `Left` text is perturbed.
- [x] 2.4 Add a missing-`git` regression test: run `isGitWorkTree` through `timedRunner` with an unresolvable `git` and assert it raises the same `IOException` as with the metrics-free runner. Verify the test passes.

## 3. Move readGitRemoteUrl onto CommandRunner (design D1, D4)

- [x] 3.1 Change `readGitRemoteUrl`, `gitRemoteOriginUrl`, and `gitRemotePushUrl` in `src/Update/GitHub.hs` to take a `CommandRunner` (`Timed`, no `wallClockProc`, same messages). Update `app/Main.hs` to pass `timedRunner (rtMetrics rt) productionCommandRunner` and `Update.GitHubToken` to pass `productionCommandRunner`. Verify `just build-release` compiles.
- [x] 3.2 Add fake-runner tests for the three functions: argv (`-C dir remote get-url [--push] origin`), the "missing or unreadable" message with and without stderr, the "empty" message, and the trimmed URL on success. Verify they pass under `just coverage`.

## 4. Metrics tests and spec (design D5)

- [x] 4.1 Rewrite `testGitProcSpans` in `test/Test/Metrics.hs` to run the git functions through `timedRunner` with a fake inner runner and fake time files. Assert a `time` object on the `rev-parse` span with no `interactive` key, and `interactive: true` with a `time` object on the `push` span. Add a case that argument redaction applies to a git argv containing the token. Verify `just coverage Metrics` passes.
- [x] 4.2 Add a test that the signing environment values passed in `prEnv` for `git commit -S` appear nowhere in the recorded `run.jsonl` content. Verify it fails if an env value is written into a span attribute.
- [x] 4.3 Run `openspec validate git-command-runner --strict` and verify it passes. Check that no residual change-delta language ("in this change", "as today") is in the spec delta.

## 5. Interrupt cleanup (design D6)

- [x] 5.0 Tag each wrapped request in `timedRunner` with `MNDZ_TIMED_REQUEST` and terminate the processes carrying it when the request raises. Verify with `Test.Metrics` cases: an interrupted real `sleep` under real GNU time leaves no process, the wrapped request carries the marker and keeps its original environment, and a request that completes keeps its background process.

## 6. Integration checks

- [x] 6.1 Run `just check` and verify it is green.
- [x] 6.2 Manual check with a real `update` that makes a signed commit and push (assets or overlay): confirm pinentry still prompts on the TTY, the signed commit succeeds, the push succeeds, and the `git commit` and `git push` spans in `run.jsonl` have `interactive: true` and a `time` object. Verify with `jq -c 'select(.ev=="span_start" and .attrs.cmd=="git")' run.jsonl`. If pinentry or signing misbehaves under the wrapper, stop and revisit design D3 before continuing. Verified on a real `update --exclude codex` (13 packages): all 39 `git commit -S` and 13 `git push` spans have `interactive: true`, a `time` object, outcome `ok` and exit 0; pinentry prompted on the TTY and the run completed.
- [x] 6.3 Manual check: Ctrl-C at the "pushing assets" status of a real `update` with a hanging fake `ssh` (`GIT_SSH` set to a script that sleeps; `GIT_SSH_COMMAND` and `core.sshCommand` are rejected by the SSH preflight). The passphrase prompts come from the SSH and GPG readiness steps, outside the measured `git` calls, so the push is the interruptible call. Verified in `run.jsonl`: `run_end` outcome `interrupted`, the `git push` span `interactive: true` ending `fail` with `AsyncCancelled`, and no fake `ssh` left running.
- [x] 6.4 Run `openspec validate git-command-runner --strict` again after the code lands and confirm the delta still matches observed span contents. No README, CONTRIBUTING, or AGENTS edit is expected because operator-facing behavior is unchanged. Verify `git diff --stat` touches none of them. Verified: the delta matches the observed spans (every git subprocess, including `remote get-url` and `rev-parse`, has a `time` object; only `commit -S` and `push` carry `interactive`), and `git diff --stat` touches none of README, CONTRIBUTING or AGENTS.

## Workflow follow-up

- Archive the change after review.
- Close out the superseded wiki handoff `run-metrics-process-runner-migration-handoff.typ`: note that its inventory was narrowed to the git sites and that the remaining sites were left on wall-clock spans because their measured cost did not justify moving them.
