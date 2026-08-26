## MODIFIED Requirements

### Requirement: engines.node requirement probe

For each candidate PV used in npm runtime-lane planning or BDEPEND alignment, the program SHALL obtain the package’s `engines.node` requirement from npm registry metadata and/or the packed package’s `package.json`. The program SHALL parse a **minimum** Node version from:

1. a bare version `X.Y.Z`, optional leading `v`, or a `>=X.Y.Z` range
2. a caret range `^X.Y.Z` (minimum `X.Y.Z`; caret upper bound is not encoded in the Portage atom)
3. a disjunction of such clauses joined by `||` (the **lowest** lower-bound among clauses)

Unparseable forms (`*`, `<`, hyphen ranges, empty, or other combinators the parser does not support) SHALL still hard-fail planning for a candidate that planning must evaluate, with an error that identifies the parse failure.

#### Scenario: openspec style engines

- **WHEN** registry metadata has `"engines": { "node": ">=20.19.0" }`
- **THEN** the required node version used for ceilings and BDEPEND is `20.19.0`

#### Scenario: caret range is a minimum

- **WHEN** a candidate’s `engines.node` is `^22.22.2`
- **THEN** the required node version used for ceilings and BDEPEND is `22.22.2`

#### Scenario: node-gyp style disjunction

- **WHEN** a candidate’s `engines.node` is `^22.22.2 || ^24.15.0 || >=26.0.0`
- **THEN** the required node version used for ceilings and BDEPEND is `22.22.2`

#### Scenario: Complex engines hard-fails plan

- **WHEN** a candidate’s `engines.node` is a complex range the parser does not support (`*`, `<`, hyphen ranges)
- **THEN** package planning hard-fails rather than silently skipping or inventing a requirement

#### Scenario: star still hard-fails plan

- **WHEN** a candidate’s `engines.node` is `*`
- **THEN** package planning hard-fails rather than silently skipping or inventing a requirement
