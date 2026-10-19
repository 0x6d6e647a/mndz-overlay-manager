# Design

## Context

See proposal.md for why a linked-worktree commit breaks the suite. Git's hook documentation exports repository-location variables and tells the hook to unset `git rev-parse --local-env-vars` before any git command in a foreign repository. `git -C` does not override those variables.

`test/Main.hs` already returns before `defaultMain` when the GPG or SSH supervisor, or the GPG tty probe, claims the process. The suite's foreign repositories are created by `test/Test/Git.hs`, `test/Test/Waves.hs`, and `isGitWorkTree` in `src/Update/Git.hs`. All of them inherit the process environment.

## Goals / Non-Goals

**Goals:**

- One clear of every name `git rev-parse --local-env-vars` prints, before the suite starts.
- A test that sets a linked worktree's `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_COMMON_DIR`, runs that clear, then initializes a temporary repository and reads `core.worktree` on the common config.

**Non-Goals:**

- No change to production git spawning, hk steps, or the six-step pipeline.
- No per-call environment filter on `callProcess "git"`.
- The child process runs one test. It does not re-exec the whole suite.

## Decisions

### Clear once in the test executable

`clearGitLocalEnv` lives in `test/Test/Git.hs`. `test/Main.hs` calls it only on the branch that runs `defaultMain`, after the supervisor and tty-probe checks. The re-exec child does not clear, and it does not run tests.

The function runs `git rev-parse --local-env-vars` and `unsetEnv`s each printed name. That list includes `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, and `GIT_INDEX_FILE`. A hardcoded subset would miss the next variable Git adds, which is how `GIT_COMMON_DIR` retargets a linked worktree. If `git` is missing or the command fails, the function leaves the environment unchanged. Tests that need git already fail in that case.

After the clear, a test that does not pass a directory still discovers this checkout through its `.git` file. Tests that pass a directory get that directory.

Alternatives:

- Unset only in the hk coverage step. Fixes `git commit` and leaves `just test` broken when the shell exports the same variables.
- Filter the environment at every `callProcess "git"`. Misses `readProcessWithExitCode "git"` inside `src/Update/Git.hs`, which the suite calls.
- Strip the variables in production `Update.Git`. Out of scope. An operator-exported `GIT_DIR` would start to be ignored.

### The proof is a child process

`setEnv` is process-wide, and the suite runs tests in parallel. Setting `GIT_DIR` in one test makes every other `git -C /tmp/...` in that process follow the linked worktree and write `core.worktree` on its common config.

The launch test builds a temporary repository, adds a linked worktree, and starts this test executable with `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_COMMON_DIR` set to that worktree. The child is the same `main`: it clears, then runs only `Cleared env temporary init`. That test initializes another temporary repository, checks that it is a work tree, and checks that the worktree's common config has no `core.worktree`. The parent does not call `setEnv`.

`MNDZ_GIT_ENV_PROBE_ROOT` passes the main repository path. It is not one of Git's local variables, so the clear leaves it set.

The unset-environment scenario is the existing `Is Git Work Tree` case. It stays as it is.

## Risks / Trade-offs

- [A test wanted the hook's `GIT_DIR` on purpose] → None do. Discovery from the process cwd still finds this checkout after the clear.
- [`git rev-parse --local-env-vars` itself is affected by `GIT_DIR`] → It still prints the variable names. The clear does not need a clean environment to learn what to unset.
- [Removing the `main` call leaves the unit test green] → The call is the only extra line on the suite path. The diff is the check.
- [Parallel tests under a hook used to race on `config.lock`] → They stop touching the invoking repository, so the lock is no longer contended by the suite.

## Migration Plan

No data migration. Revert the clear and the new test to restore the old inheritance.

## Open Questions

None.
