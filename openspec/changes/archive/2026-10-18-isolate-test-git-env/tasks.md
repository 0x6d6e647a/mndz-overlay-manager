# Tasks

## 1. Clear the inherited repository environment

- [x] 1.1 Add `clearGitLocalEnv` in `test/Test/Git.hs`. It runs `git rev-parse --local-env-vars` and unsets each printed name, and it leaves the environment unchanged when that command fails. Call it from `test/Main.hs` only on the branch that runs `defaultMain`, after the GPG and SSH supervisor checks and the GPG tty probe. Verify a test that points `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_COMMON_DIR` at a temporary linked worktree, calls the clear, initializes a repository in another temporary directory, and sees that directory as a git work tree with no `core.worktree` value on the worktree's common config. Verify the existing "Is Git Work Tree" case still passes.

## 2. Gate

- [x] 2.1 Run `openspec validate isolate-test-git-env --type change --strict` and `just check`. Verify both exit 0. Leave living `openspec/specs/` unchanged.

## Workflow follow-up

- Archive only after the tasks above are done. Sync the added requirement into `openspec/specs/git-hooks-quality-gates/spec.md`. Leave that file's Purpose as it is. A delta cannot carry Purpose, and this change does not revise it.
- Move the change to `openspec/changes/archive/YYYY-MM-DD-isolate-test-git-env/` in that archive step.
