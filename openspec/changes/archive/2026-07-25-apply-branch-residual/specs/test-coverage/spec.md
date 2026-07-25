## ADDED Requirements

### Requirement: Suite exercises applyOverlay multi-package orchestration under Integration

The test suite SHALL include Integration-isolation tests that execute product `applyOverlay` (or the product multi-package apply entrypoint) over temporary overlays with multiple packages. Tests SHALL cover sequential job execution (jobs=1) and concurrent job execution (jobs greater than 1). Tests SHALL use injectable apply environments and SHALL NOT require live network asset publish.

#### Scenario: applyOverlay sequential multi-package runs under Integration

- **WHEN** the Integration isolation suite runs under the coverage entrypoint
- **THEN** product multi-package apply orchestration runs with jobs=1 over a temporary overlay

#### Scenario: applyOverlay concurrent multi-package runs under Integration

- **WHEN** the Integration isolation suite runs under the coverage entrypoint
- **THEN** product multi-package apply orchestration runs with jobs greater than 1 over a temporary overlay

### Requirement: Suite exercises contentFix and residual check plan materialize branches under Integration

The test suite SHALL include Integration tests that execute product Check content-fix behavior for **Go**, **Npm**, **Bun**, and **Cargo** techniques (content-only reusable outcomes as product defines them) using real temporary ebuild/Manifest trees where required. The test suite SHALL also exercise residual Materialize and plan/ceiling discover branches that remain reachable with domain Ops fakes (including controlled failure arms). Tests SHALL NOT require live network for the coverage gate.

#### Scenario: contentFix for Go and Npm runs under Integration

- **WHEN** the Integration isolation suite runs under the coverage entrypoint
- **THEN** product content-fix check paths for Go and Npm are executed against controlled on-disk package trees

#### Scenario: contentFix for Bun and Cargo runs under Integration

- **WHEN** the Integration isolation suite runs under the coverage entrypoint
- **THEN** product content-fix check paths for Bun and Cargo are executed against controlled on-disk package trees

#### Scenario: Residual materialize and ceiling branches run under Integration

- **WHEN** the Integration isolation suite runs under the coverage entrypoint
- **THEN** residual product materialize failure or prune arms and runtime ceiling discover paths are executed with injectable fakes/fixtures

### Requirement: Apply-branch-residual coverage remains floor-free

Raising coverage for apply/check/plan branch residual SHALL NOT introduce numeric coverage floors or gate failure solely due to coverage percentages. Phase-one success criteria remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** apply branch residual tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
