## Why

`just clean all` leaves the `dist/` directory behind after removing the four standard flavor trees. Treating the entire directory as disposable makes full cleanup consistent with how the recipe already handles `coverage/`.

## What Changes

- **BREAKING** `just clean all` recursively removes `dist/` and `coverage/`, including custom and stale entries under `dist/`.
- Document the full cleanup scope in `CONTRIBUTING.md`.

## Capabilities

### New Capabilities

### Modified Capabilities

- `dev-task-runner` expands full cleanup to the entire `dist/` tree.

## Impact

The change affects the `clean` recipe and contributor documentation. Contributors who keep custom builds under `dist/` will lose those builds when they run `just clean all`.

## Non-Goals

Named-flavor cleanup, including the default `dev` selection, retains its current scope. Direct Cabal output in `dist-newstyle/` remains outside Just cleanup.
