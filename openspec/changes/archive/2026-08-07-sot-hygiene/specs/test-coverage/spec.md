## RENAMED Requirements

- FROM: `### Requirement: Phase-one success without numeric floors`
- TO: `### Requirement: Success without numeric floors`

## MODIFIED Requirements

### Requirement: Success without numeric floors

Successful completion of the coverage entrypoint SHALL mean: coverage-enabled tests exit successfully, and the required human and machine reports are produced. The coverage entrypoint SHALL NOT fail solely because a coverage percentage is below a numeric floor or differs from a baseline. Numeric floors and ratchet policy are outside this capability’s requirements.

#### Scenario: High coverage is not required for success

- **WHEN** tests pass under coverage and reports are written, regardless of percentage values
- **THEN** the coverage entrypoint exits successfully with respect to floor policy (no floor check)

#### Scenario: Missing reports fail the entrypoint

- **WHEN** coverage-enabled tests pass but required report artifacts cannot be produced
- **THEN** the coverage entrypoint exits with a non-zero status

### Requirement: Product module scope and excludes

Scored coverage SHALL include product modules under the library (`src/`) and, when instrumented and present in the coverage map, executable modules under `app/`. Modules that exist solely as test scaffolding or injectability seams under the library (including apply test-support modules) SHALL be excluded from the scored product denominator. The exclude list SHALL be documented next to the coverage entrypoint or in contributor documentation.

#### Scenario: TestSupport not in product denominator

- **WHEN** overall product coverage percentages are computed
- **THEN** apply test-support scaffolding modules (including `Update.Apply.TestSupport` when present) are not counted in the denominator of those product percentages

#### Scenario: Library product modules are in scope

- **WHEN** overall product coverage percentages are computed
- **THEN** non-excluded library modules under `src/` that appear in the HPC map are included in the scored set

## ADDED Requirements

### Requirement: Suite exercises required product surfaces

The test suite SHALL exercise product code (not local reimplementations) under Unit and/or Integration isolation as defined by this capability, using fakes or injectable runners so the coverage gate does not require live network, interactive pinentry, or host package-manager binaries for success. Coverage SHALL include at least:

1. **Pure and CLI** — option resolution, work-command parse edges, preflight pure helpers, version-tag and SSH-identity pure helpers, config load error messaging and path selection, overlay validation failures, GitHub token resolution edges, and technique/ecosystem/package-key pure helpers; logging bootstrap construction for controlled verbosity and color.
2. **Ecosystem builders** — pure helpers and builder entry points for npm, bun, and cargo (and Go vendor as product exposes them) with at least one successful fake-ops path and one controlled failure path per ecosystem; equal treatment across npm/bun/cargo.
3. **Check and plan** — product Check and Deps.Plan pipelines for DepsAndAssets ecosystems Go, Npm, Bun, and Cargo with injectable fetchers/plan ops; at least one multi-package or multi-phase workflow under Integration.
4. **Materialize and apply** — materialize/deps-and-assets apply paths for npm, bun, and cargo (and Go where residual gaps exist), including a reuse path when the product defines one; multi-package apply orchestration under Integration with jobs=1 and jobs greater than 1; content-fix check paths for Go, Npm, Bun, and Cargo on controlled temporary trees.
5. **Process adapters and HTTP** — production process adapters for ecosystem builders and for ebuild/egencache/portageq runners via injectable command fakes; GitHub, npm registry, and go.mod-at-tag HTTP client paths with fake HTTP responses.
6. **Agent edges** — SSH agent session lifecycle and GPG readiness process edges via injectable fakes without requiring an interactive TTY or pinentry UI for the coverage gate.

Raising or reorganizing these tests SHALL NOT introduce numeric coverage floors or gate failure solely due to coverage percentages (see “Success without numeric floors”).

#### Scenario: Coverage entrypoint runs required surface categories

- **WHEN** the coverage entrypoint completes successfully
- **THEN** Unit and Integration suites have executed product paths spanning pure/CLI, ecosystem builders, check/plan, materialize/apply, process/HTTP adapters, and agent edges as listed above

#### Scenario: No live network for the coverage gate

- **WHEN** coverage-oriented suite tests for builders, plan/check, materialize, HTTP clients, and agents run in the quality gate
- **THEN** they complete without calling public registries, live GitHub APIs, or interactive pinentry for success

#### Scenario: Floors remain unenforced after suite expansion

- **WHEN** tests pass and reports are written after suite expansion for the surfaces above
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor or differs from a baseline file

## REMOVED Requirements

### Requirement: Suite exercises pure and CLI resolver surfaces under Unit

**Reason**: Superseded by consolidated “Suite exercises required product surfaces” (pure and CLI category).

**Migration**: Rely on the pure/CLI bullets in the consolidated requirement.

### Requirement: Wave-1 coverage remains floor-free

**Reason**: Redundant with “Success without numeric floors”; wave language is change residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises npm, bun, and cargo builder surfaces equally

**Reason**: Superseded by consolidated ecosystem builders category.

**Migration**: Rely on ecosystem builders in “Suite exercises required product surfaces”.

### Requirement: Wave-2 coverage remains floor-free

**Reason**: Redundant floor rule and wave residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises product Check and Deps.Plan for all ecosystems

**Reason**: Superseded by consolidated check/plan category.

**Migration**: Rely on check/plan in the consolidated requirement.

### Requirement: Wave-3 coverage remains floor-free

**Reason**: Redundant floor rule and wave residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises Materialize apply paths for npm, bun, and cargo

**Reason**: Superseded by consolidated materialize/apply category.

**Migration**: Rely on materialize/apply in the consolidated requirement.

### Requirement: Wave-4 coverage remains floor-free

**Reason**: Redundant floor rule and wave residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises residual agent, Git, and Release HTTP surfaces

**Reason**: Superseded by consolidated process/HTTP and agent categories; “residual” is change residue.

**Migration**: Rely on process adapters, HTTP, and agent edges in the consolidated requirement.

### Requirement: Maximization program leaves floors unenforced

**Reason**: Redundant with “Success without numeric floors”; “maximization program” is change residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises pure leftover config, types, auth, and overlay surfaces under Unit

**Reason**: Superseded by pure/CLI category in the consolidated requirement; “leftover” is change residue.

**Migration**: Rely on pure/CLI bullets in “Suite exercises required product surfaces”.

### Requirement: Suite exercises residual CLI parser and logging bootstrap under Unit

**Reason**: Superseded by pure/CLI category; “residual” is change residue.

**Migration**: Rely on pure/CLI bullets in the consolidated requirement.

### Requirement: Pure leftovers coverage remains floor-free

**Reason**: Redundant floor rule and change residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises ecosystem and runner production process adapters under Unit

**Reason**: Superseded by process adapters category.

**Migration**: Rely on process adapters in the consolidated requirement.

### Requirement: Process-command-runner coverage remains floor-free

**Reason**: Redundant floor rule and change residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises GitHub npm-registry and go.mod HTTP clients under Unit with fakes

**Reason**: Superseded by HTTP category in the consolidated requirement.

**Migration**: Rely on process/HTTP bullets in the consolidated requirement.

### Requirement: Registry-http-fakes coverage remains floor-free

**Reason**: Redundant floor rule and change residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises residual SSH and GPG production process edges under Unit

**Reason**: Superseded by agent edges category; “residual” is change residue.

**Migration**: Rely on agent edges in the consolidated requirement.

### Requirement: Process-agents-residual coverage remains floor-free

**Reason**: Redundant floor rule and change residue.

**Migration**: Use “Success without numeric floors”.

### Requirement: Suite exercises applyOverlay multi-package orchestration under Integration

**Reason**: Superseded by materialize/apply category (multi-package orchestration).

**Migration**: Rely on materialize/apply in the consolidated requirement.

### Requirement: Suite exercises contentFix and residual check plan materialize branches under Integration

**Reason**: Superseded by check/plan and materialize/apply categories; “residual” is change residue.

**Migration**: Rely on check/plan and materialize/apply in the consolidated requirement.

### Requirement: Apply-branch-residual coverage remains floor-free

**Reason**: Redundant floor rule and change residue.

**Migration**: Use “Success without numeric floors”.
