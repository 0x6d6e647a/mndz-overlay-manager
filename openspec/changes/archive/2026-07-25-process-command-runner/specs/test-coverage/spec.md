## ADDED Requirements

### Requirement: Suite exercises ecosystem and runner production process adapters under Unit

The test suite SHALL include Unit-isolation tests that execute product production process adapters for **npm**, **bun**, **vendor (Go)**, and **cargo** builders (or their production Ops construction paths) and for **ebuild**, **egencache**, and **portageq** production runners as the product exposes them, using an injectable process/command runner (or equivalent scripted fake). Tests SHALL exercise at least one successful scripted process path and one controlled failure path per adapter family that is migrated. Tests SHALL NOT require live package managers, live Portage tools, or live network access for the coverage gate.

#### Scenario: Ecosystem production builders run with scripted process fakes

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product production-oriented npm, bun, Go vendor, and cargo process adapter paths are executed via injectable command/process fakes for success and failure outcomes

#### Scenario: Ebuild egencache and portageq production runners run with scripted fakes

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product production ebuild, egencache, and portageq runner paths (as migrated) are executed via injectable command/process fakes

#### Scenario: No live tools required for process-adapter coverage

- **WHEN** process-adapter coverage tests run in the quality gate
- **THEN** they do not require real npm, bun, go, cargo, ebuild, egencache, or portageq binaries on PATH for success

### Requirement: Process-command-runner coverage remains floor-free

Raising coverage for process adapters SHALL NOT introduce numeric coverage floors, ratchet baselines, or gate failure solely due to coverage percentages. Phase-one coverage success criteria remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** process-adapter Unit tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
