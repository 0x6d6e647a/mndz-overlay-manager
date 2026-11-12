# Proposal

## Why

`Update.Git` and `GitHub.readGitRemoteUrl` run `git` through `System.Process` directly, each wrapped in `wallClockProc` for a span. Every other host-side tool seam (`mkSshAgentOps`, `mkGpgAgentOps`, the ecosystem fetchers) takes an injected `CommandRunner`, so its argv construction and error mapping can be tested with scripted fakes. The git code cannot: `Test.Git` can only run real `git` in temp repos, so failure paths (a failing `git add`, a push rejection, malformed output) are reached only by contriving real repository states.

The first run-metrics data (a 3079 s `update`) shows the git calls that bypass the shared runner account for under 1% of wall time, so measurement is not the reason for this change. Testability is.

## What Changes

- **`Update.Git` takes a `CommandRunner`** in place of `Metrics` on `isGitWorkTree`, `pathsDirty`, `gitAddAndSignedCommit`, `gitPush`, and `gitRevParseHead`. `productionGitOps` builds its runner as `timedRunner m productionCommandRunner`, the way `productionSshAgentOps` does. The `GitOps` record is unchanged.
- **`GitHub.readGitRemoteUrl`** (behind `gitRemoteOriginUrl` and `gitRemotePushUrl`) takes a `CommandRunner` the same way.
- **New `Measure` variant `TimedInteractive`** in `Update.Process`. `timedRunner` treats it like `Timed` (GNU time wrapper, `proc` span, `time` object) and adds `interactive: true` to the span. `git commit -S` and `git push` use it.
- **Git subprocesses get a `time` object** in their `proc` spans. This is a side effect of moving onto the shared runner, not a goal. For `git commit -S` the CPU and RSS figures are not meaningful, because signing runs in `gpg-agent`, outside the `git` process tree.
- **Unchanged:** every git argument, working directory, signing environment, and error message, and the failure for a missing `git` binary.
- **Tests:** the real-git tests in `Test.Git` stay and pass `productionCommandRunner`. New scripted-fake tests cover argv shape, error mapping, the signing environment, and the missing-binary case. The `Test.Metrics` assertions for git spans move to the runner path.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `run-metrics`: git operations and Git remote lookups move out of "Other subprocesses have wall-clock spans" and into the GNU-time-measured subprocesses. `git commit -S` and `git push` spans carry `interactive: true` and a `time` object.

## Non-goals

- Moving any other direct process call onto `CommandRunner`: `runGpg`, `lookupPortageDistDir`, `extractV8DepsFromSnapshot`, and `ssh-add` stay on `wallClockProc`. Their measured cost does not justify it, and `ssh-add` inherits the TTY.
- `Build.GitRev` (compile time), `Metrics.Startup` (the GNU time probe, which cannot measure itself), the GPG and SSH session supervisors, and `killAgentPid` / `killSessionAgentDirect` (they run in the supervisor process, outside the recorder).
- CPU or RSS data for `tar` or `gpg`.
- Changing what any git command does, its arguments, or its error messages.
- Any change to the metrics file format, `--no-metrics`, or operator-visible CLI behavior.

## Impact

- **Code:** `src/Update/Process.hs` (`Measure`), `src/Metrics/Process.hs` (`timedRunner`), `src/Update/Git.hs`, `src/Update/GitHub.hs`, and the call sites in `src/Update/Preflight.hs`, `src/Update/GitHubToken.hs`, and `app/Main.hs`.
- **Tests:** `test/Test/Git.hs`, `test/Test/Metrics.hs`, and a new fake-runner test set for git.
- **Specs:** `run-metrics` delta only.
- **Docs:** README, CONTRIBUTING, and AGENTS are unaffected, because operator-facing behavior does not change.
- **Dependencies and build:** no new modules, no new `exposed-modules`, and no new dependencies.
