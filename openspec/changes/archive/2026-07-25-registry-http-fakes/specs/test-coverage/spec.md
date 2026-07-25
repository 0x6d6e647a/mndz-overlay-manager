## ADDED Requirements

### Requirement: Suite exercises GitHub npm-registry and go.mod HTTP clients under Unit with fakes

The test suite SHALL include Unit-isolation tests that execute product HTTP client paths for:

1. GitHub latest-version fetch and version listing, including multi-page tag listing behavior as the product implements pagination.
2. npm registry version listing and engines/node fetch (or equivalent product registry HTTP surfaces).
3. go.mod fetch at tag (or equivalent product go.mod HTTP fetch).

Tests SHALL use injectable HTTP response fakes (or HttpLbs duals exercised with fake response functions) and SHALL NOT require live network access. Tests SHALL call product library functions (not reimplementations).

#### Scenario: GitHub fetch and paginated list run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product GitHub fetch and multi-page tag listing paths are executed with fake HTTP responses covering success and at least one error class

#### Scenario: npm registry HTTP runs under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product npm registry list and engines HTTP paths are executed with fake HTTP responses

#### Scenario: go.mod HTTP fetch runs under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product go.mod-at-tag HTTP fetch is executed with fake HTTP responses

#### Scenario: No live network for registry HTTP coverage

- **WHEN** these HTTP coverage tests run in the quality gate
- **THEN** they do not contact live GitHub or npm endpoints

### Requirement: Registry-http-fakes coverage remains floor-free

Raising coverage for registry/API HTTP clients SHALL NOT introduce numeric coverage floors or gate failure solely due to coverage percentages. Phase-one success criteria remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** registry HTTP Unit tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
