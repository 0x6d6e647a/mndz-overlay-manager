## ADDED Requirements

### Requirement: Suite exercises pure leftover config, types, auth, and overlay surfaces under Unit

The test suite SHALL include Unit-isolation tests that execute product library code for residual pure and thin-IO surfaces that are not already required by earlier pure/CLI coverage waves, including:

1. Config load error messaging and default config path selection behavior (via product load entrypoints and controlled environment or override paths).
2. Overlay validation failure outcomes (not-a-directory, missing required directory, missing required file, and repo name mismatch) using temporary trees or equivalent controlled fixtures.
3. Overlay version parse/render residual edges not already covered where product helpers expose them.
4. GitHub token resolution pure edges (empty/whitespace tokens, precedence across env and config inputs) via product resolvers.
5. `Update.Types` helpers for technique asset needs, ecosystem predicates, and package-key splitting (including unsuccessful split outcomes).

These tests SHALL call product library functions (not local reimplementations of the same logic) and SHALL contribute to the Unit coverage row. Tests SHALL NOT require live network access.

#### Scenario: Config residual runs under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product config error messages for missing and decode failures are produced for controlled inputs, and default or override load path selection is exercised through the product load entrypoint

#### Scenario: Overlay validation failures run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product overlay validation is executed against controlled paths that produce not-a-directory, missing directory, missing file, and repo-name mismatch outcomes

#### Scenario: Auth and Types pure helpers run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product GitHub token pure resolution edges and package/technique/ecosystem helper predicates (including split-key failure) are executed

### Requirement: Suite exercises residual CLI parser and logging bootstrap under Unit

The test suite SHALL include Unit-isolation tests that execute remaining product CLI parser residual paths (verbosity parse edges and work-command option trees not already required) and product logging bootstrap construction (`mkLogger` / log hold APIs as exported). Top-level help exit behavior SHALL be exercised when practical under Unit without requiring a black-box executable suite. Tests SHALL call product library functions and SHALL NOT require live network access.

#### Scenario: CLI residual parse paths run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product parser evaluation covers additional verbosity or work-command edges beyond the baseline resolver cases already required

#### Scenario: Logging bootstrap construction runs under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product logging bootstrap helpers for hold and logger construction are executed for controlled verbosity and color inputs

### Requirement: Pure leftovers coverage remains floor-free

Raising coverage for pure leftover surfaces SHALL NOT introduce numeric coverage floors, ratchet baselines, or gate failure solely due to coverage percentages. Phase-one coverage success criteria (tests pass and reports produce) remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** pure leftover Unit tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
