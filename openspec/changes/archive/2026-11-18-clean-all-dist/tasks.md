## 1. Cleanup and documentation

- [x] 1.1 Update the `all` branch in `justfile` to remove `dist/` and `coverage/`. In a disposable fixture, verify that `all` removes both directories including custom entries, preserves `dist-newstyle/` and other sibling paths, and succeeds when repeated. Verify that default and named cleanup preserve sibling entries and shared reports, and that invalid selectors fail before deletion.
- [x] 1.2 Update the cleanup section in `CONTRIBUTING.md` to describe the disposable `dist/` tree and verify the documented deletion scope against the fixture.

## 2. Integration checks

- [x] 2.1 Run `openspec validate clean-all-dist --strict` and `just check`.

## Workflow follow-up

- On archive, merge the delta into the living `dev-task-runner` spec and verify that the merged requirement describes the new full cleanup scope.
