## 1. Run-id format

- [x] 1.1 Change `formatRunId` to ISO 8601 basic (`%Y%m%dT%H%M%S%z`) plus existing `-<pid>.<hex>`; update the module comment example
- [x] 1.2 Assert `formatRunId` / `openRunRootAt` run ids contain no `:`, still include `T` and `pid.hex`

## 2. Tests and docs

- [x] 2.1 Replace hardcoded extended example `2026-08-10T15:42:07-07:00-4242.a8f3` in `test/Test/TempWorkspace.hs` with `20260810T154207-0700-4242.a8f3`
- [x] 2.2 Add a README run-id example in basic form (no `:`) next to the workspace layout

## 3. Quality gate

- [x] 3.1 `openspec validate --change fix-temp-run-id-path-colons` (and `--strict` if that is the repo habit)
- [x] 3.2 `hk check` green
