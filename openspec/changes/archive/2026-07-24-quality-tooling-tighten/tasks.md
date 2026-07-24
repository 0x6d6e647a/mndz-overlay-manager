## 0. Prerequisites

- [x] 0.1 Prefer base after parts 1–7 so enabled checks do not fight mid-refactor noise

## 1. Easy hygiene

- [x] 1.1 Replace gap-line `!!` pool indexing with `NonEmpty` or non-empty pattern match
- [x] 1.2 Add cabal `synopsis` and `description` matching product purpose
- [x] 1.3 Confirm weeder roots still match `library-api-encapsulation` policy; adjust if needed

## 2. Strictness

- [x] 2.1 Apply `StrictData` or strategic bangs on hot records (progress state, `PackageEntry`, plan records) module-scoped where safe
- [x] 2.2 Run tests after each batch of strictness changes

## 3. Stan baseline

- [x] 3.1 Experimentally re-enable Performance and/or Warning (not all at once)
- [x] 3.2 Fix findings or add narrow justified excludes with comments in `.stan.toml`
- [x] 3.3 Ensure `hk check` / stan green on the new baseline

## 4. Docs and specs

- [x] 4.1 Document Stan baseline (enforced vs deferred) in `CONTRIBUTING.md`
- [x] 4.2 Keep git-hooks Stan config requirements satisfied
- [x] 4.3 Sync `project-docs` and `git-hooks-quality-gates` deltas at archive

## 5. Final verify

- [x] 5.1 Full `hk check` green
- [x] 5.2 Quality-audit program complete; archive this change
