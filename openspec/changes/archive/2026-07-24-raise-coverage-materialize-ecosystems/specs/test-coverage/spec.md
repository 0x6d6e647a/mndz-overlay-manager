## ADDED Requirements

### Requirement: Suite exercises Materialize apply paths for npm, bun, and cargo

The test suite SHALL include Unit and Integration tests that execute product Materialize / deps-and-assets apply paths for **npm**, **bun**, and **cargo** (with Go residual only where gaps remain), using injectable apply environments and operations fakes. Tests SHALL NOT require live network asset publish for the coverage gate.

#### Scenario: Per-ecosystem materialize success under Integration

- **WHEN** the Integration isolation suite runs under the coverage entrypoint
- **THEN** product materialize or deps-and-assets apply paths for npm, bun, and cargo each execute at least one successful fake-ops scenario on a temporary overlay or equivalent harness

#### Scenario: Failure or skip path under Unit or Integration

- **WHEN** materialize-oriented tests run under the coverage entrypoint
- **THEN** at least one controlled hard-fail or soft-skip product path is executed for deps-and-assets apply (across the ecosystems under test)

#### Scenario: Reuse path covered when product defines it

- **WHEN** the product defines an assets-reuse materialize path for an ecosystem under test
- **THEN** the suite includes a test that executes that reuse path under Unit or Integration isolation with fakes

### Requirement: Wave-4 coverage remains floor-free

Raising coverage for Materialize ecosystems SHALL NOT introduce numeric coverage floors or ratchet baselines.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** Wave-4 materialize tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
