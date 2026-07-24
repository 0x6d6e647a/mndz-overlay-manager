# test-coverage Specification

## Purpose

Haskell Program Coverage (HPC) instrumentation and reporting for the tasty suite: Overall / Unit / Integration breakdowns, product-module scope with scaffolding excludes, human and machine report artifacts, and phase-one gate success without numeric floors.

## Requirements

### Requirement: HPC is the coverage engine

The project SHALL measure test coverage of product Haskell code using GHC Haskell Program Coverage (HPC) via Cabal’s coverage-enabled test builds (`--enable-coverage` or equivalent). Coverage metrics SHALL be those HPC reports natively, including at least **expressions**, **alternatives**, and **booleans**. The project SHALL NOT require assembly-level, MC/DC, or non-HPC coverage tools for this capability.

#### Scenario: Coverage run uses Cabal HPC

- **WHEN** a developer or quality gate runs the documented coverage entrypoint from the repository root
- **THEN** tests are executed with coverage enabled and HPC artifacts (such as `.tix` and mix data) are produced for reporting

#### Scenario: Primary metrics are HPC-native

- **WHEN** a coverage summary report is generated
- **THEN** the summary includes percentages (or equivalent counts) for expressions, alternatives, and booleans for the scored product modules

### Requirement: Coverage broken down by test isolation level

Coverage reporting SHALL provide breakdowns for:

1. **Overall** — coverage from the full test suite (or the union of isolation-level runs).
2. **Unit** — coverage attributed to unit-isolation tests.
3. **Integration** — coverage attributed to integration-isolation tests.

**Unit** tests SHALL mean single-concern library tests that do not exercise multi-step product pipelines (apply/plan/commit spine), with I/O limited to reading small committed fixtures or pure in-memory behavior. Property-based tests (e.g. QuickCheck/`testProperty`) SHALL be classified as Unit technique, not a separate coverage row.

**Integration** tests SHALL mean tests that orchestrate multiple product modules in a workflow, mutate temporary overlay trees, or drive apply/plan environments with injectable runners and multi-phase behavior.

#### Scenario: Summary has three isolation rows

- **WHEN** the coverage entrypoint completes successfully
- **THEN** the machine-readable summary includes distinct Overall, Unit, and Integration sections (or equivalent rows) each with the required HPC metrics

#### Scenario: Property tests count as Unit

- **WHEN** the Properties (or equivalent property-based) tests run under coverage attribution
- **THEN** their contribution is included in the Unit breakdown and not as a separate isolation level

### Requirement: Product module scope and excludes

Scored coverage SHALL include product modules under the library (`src/`) and, when instrumented and present in the coverage map, executable modules under `app/`. Modules that exist solely as test scaffolding or injectability seams under the library (including `Update.Apply.TestSupport`) SHALL be excluded from the scored product denominator. The exclude list SHALL be documented next to the coverage entrypoint or in contributor documentation.

#### Scenario: TestSupport not in product denominator

- **WHEN** overall product coverage percentages are computed
- **THEN** `Update.Apply.TestSupport` is not counted in the denominator of those product percentages

#### Scenario: Library product modules are in scope

- **WHEN** overall product coverage percentages are computed
- **THEN** non-excluded library modules under `src/` that appear in the HPC map are included in the scored set

### Requirement: Human and machine report artifacts

The coverage entrypoint SHALL produce:

1. **Human-oriented** HPC markup (HTML or equivalent) for inspecting uncovered expressions.
2. **Machine-readable** summary suitable for later floor/ratchet tooling and for printing a concise table in gate logs.

Generated coverage outputs SHALL be written under a repository-documented location that is gitignored. The project SHALL NOT require committing HTML markup or `.tix` files for this capability.

#### Scenario: HTML markup is generated

- **WHEN** the coverage entrypoint completes successfully
- **THEN** markup output exists under the documented coverage output directory

#### Scenario: Machine summary is generated

- **WHEN** the coverage entrypoint completes successfully
- **THEN** a machine-readable summary file exists under the documented coverage output directory and includes Overall, Unit, and Integration metrics

#### Scenario: Generated coverage is not versioned

- **WHEN** coverage artifacts are written to the documented output directory
- **THEN** that directory (or those artifact patterns) is ignored by git

### Requirement: Phase-one success without numeric floors

Successful completion of the coverage entrypoint SHALL mean: coverage-enabled tests exit successfully, and the required human and machine reports are produced. The coverage entrypoint SHALL NOT fail solely because a coverage percentage is below a numeric floor or differs from a baseline. Numeric floors and ratchet policy are outside this capability’s requirements.

#### Scenario: High coverage is not required for success

- **WHEN** tests pass under coverage and reports are written, regardless of percentage values
- **THEN** the coverage entrypoint exits successfully with respect to floor policy (no floor check)

#### Scenario: Missing reports fail the entrypoint

- **WHEN** coverage-enabled tests pass but required report artifacts cannot be produced
- **THEN** the coverage entrypoint exits with a non-zero status

### Requirement: Documented local coverage entrypoint

The repository SHALL provide a documented command or script (invoked from the repository root) that runs coverage-enabled tests and generates the required reports, suitable for both manual use and the quality-gate pipeline.

#### Scenario: Contributor can run coverage locally

- **WHEN** a contributor follows CONTRIBUTING instructions for coverage
- **THEN** they can invoke a single documented entrypoint that produces the Overall/Unit/Integration reports without installing non-GHC coverage tools into `.tools/bin`
