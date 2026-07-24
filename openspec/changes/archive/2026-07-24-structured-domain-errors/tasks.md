## 0. Prerequisites

- [x] 0.1 Confirm `split-apply-module` is on the base branch (stable Apply.* homes)

## 1. Plan errors

- [x] 1.1 Define `PlanError` (or equivalent) ADT + pretty-printer matching current operator strings
- [x] 1.2 Convert deps/runtime plan failure paths to return the ADT; convert to `Text` at existing edges
- [x] 1.3 Cover zero planned PVs, ceiling failure, and no-candidate / no non-live local cases

## 2. Apply unit errors

- [x] 2.1 Define apply unit error ADT for dirty paths, md5 gate, missing assets-path, missing token, invalid package key
- [x] 2.2 Wire Apply.* construction of `ApplyHardFail` via pretty-printer (preserve half-applied / assets-published flags)
- [x] 2.3 Leave soft-skip and exit-code policy unchanged

## 3. Tests and deferrals

- [x] 3.1 Migrate high-value tests to assert constructors or stable pretty strings
- [x] 3.2 Explicitly leave raw HTTP `Either Text` at fetch edges unless trivial
- [x] 3.3 `cabal test all` and `hk check`

## 4. Specs and handoff

- [x] 4.1 Keep `update-apply` known hard-fail classes delta aligned with pretty-printers
- [x] 4.2 Sync `update-apply` into main specs at archive
- [x] 4.3 Ready to archive; next: `library-api-encapsulation` (if not parallel) then progress/tests
