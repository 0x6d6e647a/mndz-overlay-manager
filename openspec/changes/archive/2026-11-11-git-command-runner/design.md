# Design

## Context

See `proposal.md` for motivation and `specs/run-metrics/spec.md` for the observable contract.

- **Current git code.**
  - `Update.Git` and `GitHub.readGitRemoteUrl` each take a `Metrics` and call `wallClockProc m "git" args … (readProcessWithExitCode "git" args "")`.
  - Signed commit alone uses `readCreateProcessWithExitCode` with `env = Just env1` from `signingChildEnv`.
  - Only the `GitOps` record is injectable, and the fakes that exist replace whole operations, not the git process.
- **The shared runner.** `Update.Process.CommandRunner` is `ProcessRequest -> IO ProcessResult`. `productionCommandRunner` maps to `readCreateProcessWithExitCode`, so a missing binary throws `IOException` exactly as `readProcessWithExitCode` does.
- **`timedRunner`** (`Metrics.Process`) wraps `Timed` and `TimedContainerExec` requests in GNU time and opens a `proc` span. It resolves the executable first (`resolvable`, using `PATH` from `prEnv` when set) and runs the request unwrapped if it cannot be found, so missing-tool behavior is unchanged. It records only the redacted argv and cwd, never the environment.
- **The pattern to copy.** `productionSshAgentOps m = (mkSshAgentOps (timedRunner m productionCommandRunner)) {…}` builds the injectable record from a runner.
- **Call sites that pass `Metrics` today.** `productionGitOps` (`app/Main.hs`, two uses), `isGitWorkTree` in `app/Main.hs` and `Update.Preflight.validateAssetsPath` (`noopMetrics`), and `gitRemoteOriginUrl` / `gitRemotePushUrl` in `app/Main.hs` (`rtMetrics rt`) and `Update.GitHubToken` (`noopMetrics`).
- **Other `Measure` consumers.** `sessionExecRunner` in `Update.Process.Docker` matches on `Timed` explicitly and passes anything else through. `TimedInteractive` is a host-side git concern and never reaches it.

## Goals / Non-Goals

**Goals:**

- Every `git` invocation in `Update.Git` and `readGitRemoteUrl` goes through an injected `CommandRunner`, so tests can script it.
- Recorded behavior stays equivalent: one `proc` span per call, `interactive: true` on commit and push.
- No change to the commands run, their environment, or their error text.

**Non-Goals:**

- A general "interactive process" abstraction. `TimedInteractive` carries one attribute for the two git calls that need it.
- Moving the other bypassing sites (see the proposal's non-goals).
- Reworking `GitOps` or the GPG readiness flow in `gitAddAndSignedCommit`.

## Decisions

### D1. Functions take a `CommandRunner`, not `Metrics`

`isGitWorkTree`, `pathsDirty`, `gitAddAndSignedCommit`, `gitPush`, and `gitRevParseHead` take `CommandRunner` as their first parameter in place of `Metrics`. `productionGitOps :: Metrics -> GpgHandle -> GitOps` keeps its signature and builds `timedRunner m productionCommandRunner` internally. `gitRemoteOriginUrl`, `gitRemotePushUrl`, and `readGitRemoteUrl` take a `CommandRunner` the same way.

- **Why:** the runner is the seam tests need. The span is produced by the `timedRunner` decorator, so the functions no longer need to know about metrics.
- **Alternative:** keep `Metrics` and add an optional runner. Rejected: two parameters for one concern, and `Metrics` would be unused in the function bodies.
- **Alternative:** put the runner into `GitOps` and drop the free functions. Rejected: `Preflight` and `GitHub` call the free functions without a `GitOps`.

### D2. `TimedInteractive` as a `Measure` variant

Add `TimedInteractive` to `Measure`. In `timedRunner` it takes the same path as `Timed` (resolve the executable, wrap with GNU time, `.json` time file, `proc` span) and adds `"interactive" .= True` to the span's start attributes.

- **Why:** `Measure` already says how a request is measured, `TimedContainerExec` set the precedent, and `ProcessRequest` stays free of metrics types so `Update.Process` does not import `Metrics.Core`.
- **Alternative:** an attrs field on `ProcessRequest`. More general, but couples the neutral process seam to `Attrs`, and `interactive` is the only attribute in sight. It can be introduced later if a second attribute appears.
- **Alternative:** a variant that records the span and the attribute but skips the GNU time wrapper. Rejected: a second new variant to avoid numbers that are merely uninformative for commit.
- `Metrics.Process.timedRunner`'s case becomes `(True, Just dir, Timed) -> measured dir "" []`, `(True, Just dir, TimedInteractive) -> measured dir "" interactiveAttrs`, `(True, Just dir, TimedContainerExec) -> measured dir ".outer" []`, so `measured` takes the extra start attributes.
- `sessionExecRunner` is left alone. Its fallthrough runs a `TimedInteractive` request unwrapped, which is the right behavior for a request it should never see.

### D3. Wrap `git commit -S` and `git push` in GNU time

Both use `TimedInteractive`. All other git calls use `Timed`.

- **Why:** consistent handling, and `time` does not touch the TTY or the environment the child sees, so pinentry and the signing environment behave as before. `prEnv = Just env1` carries the signing environment unchanged.
- **Known limit:** for `git commit -S` the `time` object describes only `git` and its descendants. Signing runs in `gpg-agent`, so CPU and RSS are small and the wall time includes the agent. This is documented in the spec so it is not read as the cost of signing.
- **Verified in manual check, not assumed:** pinentry (TTY) and Ctrl-C under `time`. `tasks.md` has an explicit task. If pinentry misbehaves under the wrapper, the fallback is a non-wrapping variant (rejected above for now), which can be introduced then.

### D4. Preflight uses the undecorated runner

`Update.Preflight.validateAssetsPath` currently passes `isGitWorkTree noopMetrics`, so it records no span. It passes `isGitWorkTree productionCommandRunner`, which also records no span. `Update.GitHubToken` does the same for `gitRemoteOriginUrl`. `app/Main.hs`, which holds the live `Metrics`, passes `timedRunner (rtMetrics rt) productionCommandRunner` so its calls are spans.

- **Why:** behavior-neutral. Those two call sites run outside the recorded work today and should stay that way.

### D5. Tests

- **Keep `Test.Git`'s real-git tests**, passing `productionCommandRunner` where they passed `noopMetrics`. They cover the actual behavior of git, which a fake cannot.
- **Add scripted-fake tests** (new test group in `Test.Git`, using a recording `CommandRunner`) for: argv for each function (including `-C` root, `--` and pathspecs, `-m` message); `Timed` vs `TimedInteractive` per call; the signing environment arriving in `prEnv`; mapping of non-zero exit and stderr into the `Left` messages; empty and trimmed stdout for `rev-parse` and `get-url`; `gitAddAndSignedCommit` not running `git add` when GPG readiness fails.
- **Missing binary regression:** a test that runs the function through `timedRunner` with an unresolvable `git` (via an empty `PATH` in `prEnv`) and asserts it raises the same `IOException` as without metrics.
- **`Test.Metrics`:** `testGitProcSpans` is rewritten to run through `timedRunner` with a fake inner runner and fake time files. It asserts a `time` object on `rev-parse`, no `interactive` on `rev-parse`, and `interactive: true` on `push`.

### D6. Interrupted requests reap their processes

GNU time does not forward SIGTERM, and the shared runner cancels a request by terminating its direct child. Under the wrapper that child is `time`, so the command it started keeps running. Found by an interrupt test with a real `sleep` under the real wrapper. A terminal Ctrl-C is unaffected, because SIGINT reaches the whole foreground process group.

`timedRunner` sets `MNDZ_TIMED_REQUEST=<time file name>` in the environment of every wrapped request (the request's own environment, or the program's when it has none). When the inner runner raises, `timedRunner` scans `/proc/*/environ` for that marker, sends SIGTERM to the matches, waits up to one second, then sends SIGKILL to any survivor. It does this only on the exception path.

- **Why a marker:** after `time` dies its children reparent to init, so the process tree no longer leads to them. The environment is inherited through the whole tree and survives reparenting.
- **Alternative:** `setpriv --pdeathsig=TERM` between `time` and the command. Rejected: a new external dependency and a new startup probe, and it reaches only the direct child.
- **Alternative:** a new process group per request and `killpg`. Rejected: a background group cannot read the TTY, which breaks pinentry and SSH prompts.
- **Limits:** a process that clears its environment is not found. A daemon the interrupted request started is also terminated.
- **Scope:** applies to every measured tool, not only git.

## Risks / Trade-offs

- **[Pinentry or Ctrl-C regresses under `time`]** → manual check task before archiving, and the fallback in D3.
- **[Extra fork/exec per git call]** → about a millisecond each. There are around a hundred git calls per run, and the bypassing git calls were under 1% of wall time.
- **[Marker leaks into the command's environment]** → harmless for the tools run; the value is not recorded in spans.
- **[Misleading CPU figure on `git commit -S`]** → spec scenario states the limit.
- **[A caller keeps passing `Metrics`]** → the type change makes this a compile error. The call-site list in Context is exhaustive per `grep`.
- **[Real-git tests and fakes drift]** → fakes assert argv and error mapping only. Behavior assertions stay in the real-git tests.

## Migration Plan

Internal refactor, no operator-visible change and no data migration. Rollback is a revert.
