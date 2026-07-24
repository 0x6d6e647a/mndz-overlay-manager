## 0. Prerequisites

- [x] 0.1 Confirm `split-apply-module` is on the base branch

## 1. Inventory

- [x] 1.1 List modules imported by `app/Main.hs`
- [x] 1.2 List modules imported by the test suite
- [x] 1.3 Derive candidate `exposed-modules` vs `other-modules`

## 2. Cabal surface

- [x] 2.1 Shrink `exposed-modules` to the inventory-driven set; move the rest to `other-modules`
- [x] 2.2 Ensure executable and test-suite still compile
- [x] 2.3 Clarify test-only Apply hooks (dedicated module or documented re-exports)

## 3. Weeder

- [x] 3.1 Replace blanket `root-modules` with entrypoint-oriented roots (`Main.main`, justified public roots only)
- [x] 3.2 Fix genuine weeds or delete dead code; do not re-blanket
- [x] 3.3 Confirm weeder delta requirement: roots are not a full-module list

## 4. Docs

- [x] 4.1 Update `AGENTS.md` with guidance against blanket weeder roots and unjustified exposed-modules expansion
- [x] 4.2 Sync delta specs for `project-docs` and `git-hooks-quality-gates` into main specs at archive time

## 5. Verify

- [x] 5.1 `cabal test all` and `hk check` green
- [x] 5.2 Ready to archive; next: `progress-soft-skip-semantics` / `test-suite-modularize`
