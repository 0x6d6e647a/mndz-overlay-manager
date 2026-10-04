## MODIFIED Requirements

### Requirement: Documented local coverage entrypoint

The repository SHALL provide a documented command, invoked from the repository root, that runs coverage-enabled tests on the debug coverage flavor and generates the required reports. That command SHALL be the blocking coverage step of the quality gate. The debug coverage flavor SHALL be compiled without optimization and SHALL include debug info and runtime stack provenance so a failing gate process can be rerun under a debugger or with the runtime's stack dump.

The repository SHALL also provide a documented optimized coverage command that instruments the release flavor. That command SHALL NOT be the blocking coverage step of the quality gate, and it SHALL NOT replace the debug coverage flavor's build products.

Both commands SHALL be suitable for manual use. Neither SHALL require non-GHC coverage tools under `.tools/bin`.

#### Scenario: Contributor can run coverage locally

- **WHEN** a contributor follows CONTRIBUTING instructions for coverage
- **THEN** they can invoke a single documented entrypoint that builds the debug coverage flavor and produces the Overall/Unit/Integration reports

#### Scenario: Gate coverage binary is the debug flavor

- **WHEN** the documented gate coverage entrypoint builds the test suite
- **THEN** the suite runs from the unoptimized debug coverage flavor, not from the optimized coverage flavor

#### Scenario: Optimized coverage is separate

- **WHEN** a contributor runs the documented optimized coverage command
- **THEN** the release flavor is instrumented, the debug coverage flavor's build products remain, and the quality gate does not treat that command as its coverage step

## ADDED Requirements

### Requirement: Failing gate coverage can be diagnosed

Contributor and agent documentation SHALL state that a failure of the gate coverage entrypoint is a debug-coverage binary, and SHALL state how to rerun a single test pattern on that same flavor and how to request a runtime stack dump from that binary.

#### Scenario: Docs name the debug rerun

- **WHEN** a contributor or agent reads the documented recovery for a failing coverage gate
- **THEN** the documentation names the debug coverage flavor, the single-pattern rerun, and the runtime stack dump
