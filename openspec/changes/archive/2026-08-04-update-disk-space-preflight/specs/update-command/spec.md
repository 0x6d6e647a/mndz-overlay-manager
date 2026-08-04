## ADDED Requirements

### Requirement: Update runs disk-space feasibility before package mutation

After tool, assets, and manager-distfiles usability preflight succeed, and before concurrent per-package mutation that can open heavy temporary trees or fetch distfiles, `update` SHALL run the disk-space feasibility gate defined by `disk-space-preflight` for the selected packages that need work. Failure of that gate SHALL log an error and exit with status `1` without applying package updates. When activity indicators are enabled, the preflight progress presentation SHALL include a step covering disk-space evaluation (either as its own step or clearly part of sequential preflight).

#### Scenario: Insufficient free space blocks update

- **WHEN** the user runs `update` for packages that need full-path materialize and free space on the effective temp root is below the concurrent sum required by `disk-space-preflight`
- **THEN** the program logs an actionable free-space error and exits with status `1` before package mutation

#### Scenario: Sufficient free space allows package work

- **WHEN** the user runs `update` with tools and distfiles probe ok and free space satisfies max and concurrent-sum needs on hard-check filesystems
- **THEN** the program proceeds to per-package update work

#### Scenario: No heavy write units skips hard gate failure

- **WHEN** selected packages need no heavy temp materialize and no manager distfiles fetch that requires additional free space under `disk-space-preflight` estimation
- **THEN** the program does not hard-fail solely for low temp free space that would only matter for full materialize
