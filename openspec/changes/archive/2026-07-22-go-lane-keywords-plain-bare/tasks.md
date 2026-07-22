## 1. KEYWORDS assembly

- [x] 1.1 Change `assembleKeywords` (or successor) to take lane membership (arch + tier), emitting bare `arch` when any plain lane targets the PV and `~arch` only when tilde-only for that arch
- [x] 1.2 Wire `collapsePlannedEbuilds` to pass `peLanes` / lane tiers into assembly so planned `peKeywords` match the new rule
- [x] 1.3 Keep deterministic token order (`amd64` then `arm64`; never both bare and `~` for the same arch)

## 2. Apply and content-fix

- [x] 2.1 Confirm apply/`setKeywords` write bare tokens when the plan includes them (no tilde-only filter remaining)
- [x] 2.2 Confirm `keywordsMatch` / content-fix treat bare vs `~` drift as needing materialization (revbump path for already-local PVs)
- [x] 2.3 Grep for hard-coded “always `~amd64`” assumptions in apply/check helpers and update them

## 3. Tests

- [x] 3.1 Update `testGoKeywordsAssembly` / collapse tests: all-four-lanes → bare `amd64 arm64`; tilde-only → `~arch`; staggered plain/tilde split cases from the delta specs
- [x] 3.2 Update any apply/outdated fixtures that assert KEYWORDS tilde-only when plain lanes are present
- [x] 3.3 Add or adjust a content-fix expectation when planned KEYWORDS upgrade `~amd64` → `amd64`

## 4. Quality gate

- [x] 4.1 Run `hk check` (or full CONTRIBUTING pipeline) and fix failures
- [x] 4.2 Mark change ready for apply archive only after gates are green
