## ADDED Requirements

### Requirement: Suite exercises pure and CLI resolver surfaces under Unit

The test suite SHALL include Unit-isolation tests that execute product code for CLI option resolution and pure helpers used by preflight, version tag parsing, SSH identity parsing, quote stripping, and pure Check status/grouping helpers. These tests SHALL call product library functions (not local reimplementations of the same logic) and SHALL contribute to the Unit coverage row.

#### Scenario: CLI resolver and parser pure paths run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product code paths for verbosity/color/jobs resolution and pure parsing of work-command option trees are executed (for example via pure `optparse-applicative` evaluation of the product parser)

#### Scenario: Preflight and pure Check helpers run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product preflight tool-check helpers and pure Check helpers such as status comparison and package grouping are executed with controlled inputs or injectable finders

#### Scenario: Tag parse and identity parse edges run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product helpers for stripping version-tag prefixes and parsing SSH identity file lists (and related pure candidates) are executed for both success and rejection or empty-input edges where those behaviors exist

### Requirement: Wave-1 coverage remains floor-free

Raising coverage for pure and CLI surfaces SHALL NOT introduce numeric coverage floors, ratchet baselines, or gate failure solely due to coverage percentages. Phase-one coverage success criteria (tests pass and reports produce) remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** Wave-1 pure and CLI tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
