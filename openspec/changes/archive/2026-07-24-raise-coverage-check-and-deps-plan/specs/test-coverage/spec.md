## ADDED Requirements

### Requirement: Suite exercises product Check and Deps.Plan for all ecosystems

The test suite SHALL execute product Check and Deps.Plan pipelines (not local reimplementations of those pipelines) for DepsAndAssets ecosystems **Go, Npm, Bun, and Cargo** with injectable fetchers and plan operations. Coverage SHALL include both Unit and Integration isolation levels as defined by the existing isolation rule.

#### Scenario: Product Check APIs are invoked

- **WHEN** outdated/check-oriented tests run under the coverage entrypoint
- **THEN** product Check entry points (such as per-package check or overlay check with deps plan) execute for controlled fake fetch/plan inputs, and tests do not rely solely on a test-local reimplementation of check status selection

#### Scenario: Deps plan runs per ecosystem under Unit or Integration

- **WHEN** plan-oriented tests run under the coverage entrypoint
- **THEN** product deps-plan entry points are executed for each of Go, Npm, Bun, and Cargo with mocked version lists and/or engine probes and without live network access

#### Scenario: Integration exercises multi-package or multi-phase plan/check

- **WHEN** the Integration isolation suite runs under the coverage entrypoint
- **THEN** at least one multi-package or multi-phase product Check or Deps.Plan workflow is attributed to Integration coverage

### Requirement: Wave-3 coverage remains floor-free

Raising coverage for Check and Deps.Plan SHALL NOT introduce numeric coverage floors or ratchet baselines.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** Wave-3 check/plan tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
