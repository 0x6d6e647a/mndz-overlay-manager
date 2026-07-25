## ADDED Requirements

### Requirement: Suite exercises residual SSH and GPG production process edges under Unit

The test suite SHALL include Unit-isolation tests that execute residual product production process paths for SSH agent session handling using **captured I/O style** fakes (agent start/parse, identity listing, teardown/kill, and non-interactive add paths as product exposes them) and residual GPG readiness process edges not already covered by prior agent Unit tests. Tests SHALL use injectable Ops and/or command/process fakes. Tests SHALL NOT require an interactive TTY, pinentry UI, or live network for the coverage gate. Full interactive ssh-add TTY/askpass coverage is not required for this requirement.

#### Scenario: Captured SSH production paths run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product SSH agent production helpers for captured session lifecycle paths are executed via fakes for success and at least one failure class

#### Scenario: Residual GPG process edges run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** residual product GPG process-oriented paths are executed via injectable fakes

#### Scenario: No interactive pinentry required

- **WHEN** these agent residual tests run in the quality gate
- **THEN** they do not require an interactive pinentry or `/dev/tty` session for success

### Requirement: Process-agents-residual coverage remains floor-free

Raising coverage for agent process residual SHALL NOT introduce numeric coverage floors or gate failure solely due to coverage percentages. Phase-one success criteria remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** agent residual Unit tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor
