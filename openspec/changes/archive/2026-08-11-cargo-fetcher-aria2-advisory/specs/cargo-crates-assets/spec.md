## MODIFIED Requirements

### Requirement: Cargo preflight tools

When any package that **needs work** uses `DepsAndAssets Cargo`, preflight SHALL require `pycargoebuild` on PATH and at least one fetcher usable by pycargoebuild among the executable names **`wget`** and **`aria2c`** only. Preflight SHALL NOT treat a binary named `aria2` (without the `c` suffix) as satisfying the fetcher requirement. Failure when `pycargoebuild` or both fetchers are missing SHALL hard-fail before package work with a message that names the missing tool(s). Preflight SHALL NOT require host `rustc` solely for cargo packaging.

#### Scenario: Missing pycargoebuild

- **WHEN** `update` selects `dev-util/mise` and `pycargoebuild` is not executable on PATH
- **THEN** preflight fails before apply

#### Scenario: Missing both wget and aria2c

- **WHEN** a cargo package needs work and neither `wget` nor `aria2c` is executable on PATH
- **THEN** preflight fails before package mutation with a message that names the missing fetcher requirement

#### Scenario: aria2 alone does not satisfy fetcher preflight

- **WHEN** a cargo package needs work, `aria2` is on PATH, and neither `wget` nor `aria2c` is on PATH
- **THEN** preflight fails the fetcher requirement (pycargoebuild invokes `aria2c`, not `aria2`)

## ADDED Requirements

### Requirement: Soft advisory when cargo full path will use wget

When language-tool preflight runs after reuse/full classification, and at least one needs-work unit is classified **full path** for ecosystem `Cargo`, and `aria2c` is **not** executable on PATH, and hard fetcher preflight still succeeds (so `wget` is available), the program SHALL emit a soft advisory that does **not** fail preflight or change exit status solely for this condition. The advisory text SHALL be exactly:

`pycargoebuild is using wget; install aria2 for faster crate fetches`

The program SHALL log that advisory at warn severity when the condition is detected (before package mutation begins for those units) **and** SHALL include the same text in the update run’s collected warnings surface (the same channel used for other non-fatal update warnings such as Portage DISTDIR free-space notes). When no full-path cargo unit is planned, or when `aria2c` is on PATH, the program SHALL NOT emit this advisory solely for cargo fetcher tooling.

#### Scenario: Full-path cargo with wget only warns once

- **WHEN** `update` will full-path materialize a cargo package, `wget` is on PATH, and `aria2c` is not
- **THEN** preflight succeeds and the advisory text above is logged at warn and included in the run’s collected warnings

#### Scenario: aria2c present no advisory

- **WHEN** `update` will full-path materialize a cargo package and `aria2c` is on PATH
- **THEN** the program does not emit the wget/aria2 speed advisory solely for that package set

#### Scenario: Reuse-only cargo no advisory

- **WHEN** a cargo package needs work but every cargo unit is classified reuse (no full-path cargo materialize)
- **THEN** the program does not emit the wget/aria2 speed advisory solely for missing `aria2c`
