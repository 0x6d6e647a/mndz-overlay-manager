# Tasks

## 1. Cleanup recipe and contributor workflow

- [x] 1.1 Add the `clean` recipe to the justfile. Verify in a disposable fixture that the default, each explicit flavor, and `all` delete only the specified paths, including release HIE with release cleanup. Verify that repeated cleanup succeeds and that unsupported or path-like inputs fail with fixture contents intact. Include sentinel files in `dist-newstyle/` and unrelated `dist/` entries.
- [x] 1.2 Document the default, supported selectors, shared coverage report behavior, and direct Cabal boundary in CONTRIBUTING.md. Replace the manual stale-HIE cleanup example with `just clean release && just build-release` and verify the documented invocations agree with the spec and fixture checks.

## 2. Integration verification

- [x] 2.1 Run `openspec validate add-just-clean --strict` and the full `just check` gate. Mark tasks complete after the relevant checks pass.

## Workflow follow-up

- When archiving, merge the cleanup delta into the living `dev-task-runner` spec and verify that the resulting requirements describe current behavior.
