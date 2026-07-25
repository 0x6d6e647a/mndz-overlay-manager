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

### Requirement: Suite exercises pure and CLI resolver surfaces under Unit

The test suite SHALL include Unit-isolation tests that execute product code for CLI option resolution and pure helpers used by preflight, version tag parsing, SSH identity parsing, quote stripping, and pure Check status/grouping helpers. These tests SHALL call product library functions (not local reimplementations of the same logic) and SHALL contribute to the Unit coverage row.

#### Scenario: CLI resolver and parser pure paths run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product code paths for verbosity/color/jobs resolution and pure parsing of work-command option trees are executed (for example via pure `optparse-applicative` evaluation of the product parser)

#### Scenario: Preflight and pure Check helpers run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product preflight tool-check helpers and pure Check helpers such as status comparison and package grouping are executed with controlled inputs or injectable finders

#### Scenario: Tag parse and identity parse edges run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product helpers for stripping version-tag prefixes and parsing SSH identity file lists (and related pure candidates) are executed for both success and rejection or empty-input edges where those behaviors exist

### Requirement: Wave-1 coverage remains floor-free

Raising coverage for pure and CLI surfaces SHALL NOT introduce numeric coverage floors, ratchet baselines, or gate failure solely due to coverage percentages. Phase-one coverage success criteria (tests pass and reports produce) remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** Wave-1 pure and CLI tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor

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

### Requirement: Suite exercises residual agent, Git, and Release HTTP surfaces

The test suite SHALL include Unit and/or Integration tests that execute residual product surfaces for SSH agent session handling, GPG readiness edges not already covered, Git operations edges via injectable git ops, and Assets.Release HTTP-oriented paths (download/create/delete as product exposes them) using fakes rather than live agents or live GitHub API access in the coverage gate.

#### Scenario: SSH and GPG residual paths run with fakes

- **WHEN** agent-oriented tests run under the coverage entrypoint
- **THEN** product SSH session and/or GPG readiness code paths beyond the pre-wave baseline are executed with injectable ops or controlled environment fakes

#### Scenario: Git and Release residual paths run with fakes

- **WHEN** Git- and Release-oriented residual tests run under the coverage entrypoint
- **THEN** product Git ops edge paths and Assets.Release HTTP-oriented paths are executed without requiring interactive pinentry or live GitHub network access

#### Scenario: Http and Npm fetch residual when still thin

- **WHEN** after prior waves Http or Npm fetch product modules remain largely unexercised
- **THEN** the suite includes Unit and/or Integration tests that execute those fetch paths via fakes or injectable managers

### Requirement: Maximization program leaves floors unenforced

After residual coverage tests land, the coverage entrypoint SHALL still succeed based on tests and report production only. Numeric floors and ratchet baselines SHALL remain out of scope for this residual wave (a separate change may introduce them later).

#### Scenario: No floor enforcement after residual wave

- **WHEN** Wave-5 residual tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor or differs from a baseline file

### Requirement: Suite exercises pure leftover config, types, auth, and overlay surfaces under Unit

The test suite SHALL include Unit-isolation tests that execute product library code for residual pure and thin-IO surfaces that are not already required by earlier pure/CLI coverage waves, including:

1. Config load error messaging and default config path selection behavior (via product load entrypoints and controlled environment or override paths).
2. Overlay validation failure outcomes (not-a-directory, missing required directory, missing required file, and repo name mismatch) using temporary trees or equivalent controlled fixtures.
3. Overlay version parse/render residual edges not already covered where product helpers expose them.
4. GitHub token resolution pure edges (empty/whitespace tokens, precedence across env and config inputs) via product resolvers.
5. `Update.Types` helpers for technique asset needs, ecosystem predicates, and package-key splitting (including unsuccessful split outcomes).

These tests SHALL call product library functions (not local reimplementations of the same logic) and SHALL contribute to the Unit coverage row. Tests SHALL NOT require live network access.

#### Scenario: Config residual runs under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product config error messages for missing and decode failures are produced for controlled inputs, and default or override load path selection is exercised through the product load entrypoint

#### Scenario: Overlay validation failures run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product overlay validation is executed against controlled paths that produce not-a-directory, missing directory, missing file, and repo-name mismatch outcomes

#### Scenario: Auth and Types pure helpers run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product GitHub token pure resolution edges and package/technique/ecosystem helper predicates (including split-key failure) are executed

### Requirement: Suite exercises residual CLI parser and logging bootstrap under Unit

The test suite SHALL include Unit-isolation tests that execute remaining product CLI parser residual paths (verbosity parse edges and work-command option trees not already required) and product logging bootstrap construction (`mkLogger` / log hold APIs as exported). Top-level help exit behavior SHALL be exercised when practical under Unit without requiring a black-box executable suite. Tests SHALL call product library functions and SHALL NOT require live network access.

#### Scenario: CLI residual parse paths run under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product parser evaluation covers additional verbosity or work-command edges beyond the baseline resolver cases already required

#### Scenario: Logging bootstrap construction runs under Unit

- **WHEN** the Unit isolation suite runs under the coverage entrypoint
- **THEN** product logging bootstrap helpers for hold and logger construction are executed for controlled verbosity and color inputs

### Requirement: Pure leftovers coverage remains floor-free

Raising coverage for pure leftover surfaces SHALL NOT introduce numeric coverage floors, ratchet baselines, or gate failure solely due to coverage percentages. Phase-one coverage success criteria (tests pass and reports produce) remain in force.

#### Scenario: Coverage entrypoint still ignores percentages

- **WHEN** pure leftover Unit tests pass and coverage reports are written
- **THEN** the coverage entrypoint does not fail because a percentage is below a floor

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
