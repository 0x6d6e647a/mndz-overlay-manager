## 1. Baseline and wiring

- [x] 1.1 Run `./scripts/coverage` and note Overall expr/alt/bool plus Wave-1 target modules (CLI.Parser, Preflight, TextUtil, GitHub stripAndParse, Ssh pure, Check pure, Http, Npm)
- [x] 1.2 Confirm Unit group placement in `test/Main.hs` for any new test modules

## 2. CLI.Parser Unit tests

- [x] 2.1 Add Unit tests for `resolveColorMode` (on/off/auto or product modes and env/flag precedence as implemented)
- [x] 2.2 Add Unit tests for `resolveJobs` (bounds, default, explicit)
- [x] 2.3 Add `execParserPure` (or equivalent) cases for list, outdated, update, gencache command trees and key global flags without spawning the binary

## 3. Preflight and TextUtil

- [x] 3.1 Expand `checkToolsOnPath` cases; assert required tool list constants for update/assets/go/npm/bun/cargo as exported
- [x] 3.2 Unit-test `validateAssetsPath` and `preflightUpdateTools` with injectable directory/executable fakes (success and failure)
- [x] 3.3 Unit-test `stripSurroundingQuotes` both sides (quoted, unquoted, mismatched)

## 4. GitHub / Ssh / Check pure

- [x] 4.1 Expand `stripAndParse` edges (empty prefix, non-matching tag, valid tags, bad versions)
- [x] 4.2 Unit-test `defaultIdentityCandidates` and additional `parseIdentityFiles` cases
- [x] 4.3 Call real `statusFromCompare`, `groupNewest`, and `groupByPackage` (or equivalent exports) with fixture data—do not implement full Check pipeline

## 5. Http / Npm reachability

- [x] 5.1 If tests cannot import `Update.Http` / `Update.Npm`, expose them for the test-suite in cabal with minimal blast radius
- [x] 5.2 Add Unit tests for `tryHttp` / `fetchHttpWith` / `fetchNpmWith` error and success branches using fakes or injectable managers as practical

## 6. Verify

- [x] 6.1 Run `./scripts/coverage`; confirm Wave-1 targets are no longer trivially dark; record Overall delta in change notes if useful
- [x] 6.2 Run `hk check` and fix all gate failures
- [x] 6.3 Confirm no numeric floors were introduced

### Coverage notes (6.1)

Baseline → after Wave 1 (Overall product modules; floors not enforced):

| Level | expr% before | expr% after | alt% before | alt% after | bool% before | bool% after |
|-------|--------------|-------------|-------------|------------|--------------|-------------|
| Overall | 45.3 | 48.4 | 36.9 | 39.1 | 21.0 | 26.7 |
| Unit | 32.7 | 35.8 | 27.4 | 29.8 | 16.9 | 23.0 |

Wave-1 modules (approx expr% from HPC index after): CLI.Parser ~50% (was ~4%), Preflight ~69% (was ~23%), TextUtil 100%, Http ~66% (was 0%), Npm ~50% (was 0%), Check pure helpers exercised, Ssh pure paths expanded.
