# Proposal

## Why

A commit from a linked worktree runs the pre-commit coverage suite with Git's hook environment still set (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_INDEX_FILE`, and the rest). Temporary `git init` and `git -C` calls then follow that environment instead of the directory the test named. The suite reports those directories as not work trees, and one of the inits writes `core.worktree` on the shared repository config, which retargets the main checkout.

## What Changes

- Before any test runs, the test executable drops every variable named by `git rev-parse --local-env-vars`.
- A test builds a linked worktree, exports that environment, and checks that a temporary `git init` creates a repository in the temporary directory and does not set `core.worktree` on the worktree's common config.
- Production git commands are unchanged. They still inherit the operator's environment.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `git-hooks-quality-gates`: The blocking test gate, including when a git hook has exported its repository environment, creates and inspects the temporary repositories the tests name. It does not retarget the repository that invoked the hook.

## Impact

- `test/Main.hs` clears the variables after the GPG and SSH supervisor checks and before the suite starts. The supervisor child never reaches that clear.
- One new test covers the linked-worktree environment. Existing Git and Waves helpers stay as they are. They already pass a directory to git. They fail only while the hook environment is inherited.
- No operator CLI, config key, README, CONTRIBUTING, or AGENTS change. The pipeline steps in `hk.pkl` stay the same.
- No change to `src/Update/Git.hs` or to how an operator-started run locates an overlay.

## Non-goals

- Do not strip `GIT_DIR` or `GIT_WORK_TREE` from production git commands. An operator who exports them still affects the manager.
- Do not unset the variables only in the hk coverage step. `just test` from a shell that exports the same variables would stay broken.
- Do not teach every `callProcess "git"` to filter its own environment.
- Do not change hook installation, the six pipeline steps, or tool pins.
