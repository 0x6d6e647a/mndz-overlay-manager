# Proposal

## Why

Contributors currently delete build directories by hand to force a fresh build or clear stale release HIE. A Just recipe makes the cleanup scope explicit and preserves the incremental builds for other flavors when only one needs a reset.

## What Changes

- Add `just clean [flavor]`, defaulting to `dev`, with an explicit `all` option for all Just-managed build trees and the shared coverage reports.
- Document cleanup in CONTRIBUTING.md and use `just clean release && just build-release` for stale HIE recovery.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `dev-task-runner` gains a build cleanup recipe with explicit flavor selection.

## Impact

The contributor task runner and its documentation gain a cleanup command.

## Non-goals

Direct Cabal output in `dist-newstyle/`, installed tools, and manager runtime data are outside the cleanup scope.
