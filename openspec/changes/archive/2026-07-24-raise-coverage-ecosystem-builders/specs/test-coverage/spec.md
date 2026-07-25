## ADDED Requirements

### Requirement: Suite exercises npm, bun, and cargo builder surfaces equally

The test suite SHALL include tests that execute product DepsAndAssets builder/cache modules for **npm**, **bun**, and **cargo** with equal treatment (analogous pure and builder scenarios for each ecosystem). Tests SHALL use injectable operations records or equivalent fakes and SHALL NOT require live registry or remote network access for the coverage gate.

#### Scenario: Pure ecosystem helpers run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product pure helpers for each of npm, bun, and cargo (such as engine/version gate checks, version requirement messages, or distfile naming constants as exported) are executed

#### Scenario: Builder success and failure run with fakes

- **WHEN** the Unit (and Integration, when present) suites run under the coverage entrypoint
- **THEN** product builder entry points for npm deps, bun deps, and cargo crates tarballs are exercised for at least one successful fake-ops path and one controlled failure path per ecosystem

#### Scenario: No live network required for builder coverage

- **WHEN** ecosystem builder coverage tests run in the quality gate
- **THEN** they complete without calling public npm/crates.io/GitHub network endpoints

### Requirement: Wave-2 coverage remains floor-free

Raising coverage for ecosystem builders SHALL NOT introduce numeric coverage floors or ratchet baselines.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** Wave-2 builder tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
