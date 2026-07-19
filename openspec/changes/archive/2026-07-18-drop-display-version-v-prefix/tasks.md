## 1. Core display render

- [x] 1.1 Change `prettyVersion` in `src/Overlay/Version.hs` to emit PV form without a leading `v` (equivalent to `renderPV`); update haddock
- [x] 1.2 Confirm no remaining hard-coded display prefix (`"v" <>` or similar) outside GitHub tag-prefix handling

## 2. Tests

- [x] 2.1 Update `testVersionRender` in `test/Main.hs` to expect `1.5.3-r2` and `2.1.10` (not `v…`)
- [x] 2.2 Leave tag-prefix / go.mod fixture strings that represent real upstream tags unchanged

## 3. Specs and housekeeping

- [x] 3.1 After implementation, ensure main specs will match deltas (`ebuild-version`, `outdated-command`, `update-command`) when the change is archived/synced
- [x] 3.2 Check off the related item in `MNDZ.md` (“Drop the `v` prefix…”)

## 4. Quality gate

- [x] 4.1 Run `hk fix` / format as needed
- [x] 4.2 Run `hk check` (or full build/test + hlint/stan/weeder pipeline) and fix any fallout
