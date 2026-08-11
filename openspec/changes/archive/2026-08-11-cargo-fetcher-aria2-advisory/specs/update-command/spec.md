## MODIFIED Requirements

### Requirement: Update preflight requires git ebuild and gpg

The `update` command SHALL verify that `git`, `ebuild`, `egencache`, and `gpg` are available on `PATH` before package mutation (spine tools). Spine tools SHALL be checked before the plan phase.

When at least one selected package **that needs work** will attempt a `DepsAndAssets` apply (including same-PV content/revision fixes), `update` SHALL additionally verify that `xz` is available on `PATH`, that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. When any such package will use the **full** materialize path for ecosystem `Go`, `go` SHALL be on `PATH`. When any will use the full path for ecosystem `Npm`, `npm` SHALL be on `PATH`. When any will use the full path for ecosystem `Bun`, `bun` SHALL be on `PATH`. When any package that **needs work** uses ecosystem `Cargo` (including when all units may later reuse assets), `pycargoebuild` SHALL be on `PATH` and at least one of **`wget` or `aria2c`** SHALL be on `PATH` (executable names; not bare `aria2`). Missing conditional hard requirements SHALL log an error and exit with status `1` before package mutation. When no package that needs work will attempt `DepsAndAssets`, the program SHALL NOT fail preflight solely because `go`, `npm`, `bun`, `pycargoebuild`, fetchers, `xz`, assets path, or token are missing. Packages that only need the reuse path SHALL NOT require the language tool (`go`/`npm`/`bun`) solely for that reuse work; Cargo still requires `pycargoebuild` and a fetcher in preflight whenever any cargo `DepsAndAssets` package **needs work** (P1).

When language-tool preflight runs after reuse/full classification and at least one unit is **full-path** cargo while `aria2c` is missing but hard fetcher preflight passed, `update` SHALL soft-advise as specified by `cargo-crates-assets` (warn log + collected run warnings) without hard-failing solely for that advisory.

Conditional assets and language-tool requirements that depend on needs-work or full vs reuse SHALL be evaluated **after** the plan phase (and after reuse/full classification for language tools), not solely from technique presence in the full selected inventory.

#### Scenario: Go tools required only when Go technique selected

- **WHEN** the user runs `update dev-util/crush` and crush will attempt full-path `DepsAndAssets` Go work
- **THEN** preflight requires `go` and `xz` on `PATH`

#### Scenario: npm required for openspec full path

- **WHEN** the user runs `update dev-util/openspec` and openspec will attempt full-path npm cache construction
- **THEN** preflight requires `npm` and `xz` on `PATH`

#### Scenario: bun required for ralph-tui full path

- **WHEN** the user runs `update dev-util/ralph-tui` and ralph-tui will attempt full-path bun cache construction
- **THEN** preflight requires `bun` and `xz` on `PATH`

#### Scenario: bun required for opencode full path

- **WHEN** the user runs `update dev-util/opencode` and opencode will attempt full-path bun cache construction
- **THEN** preflight requires `bun` and `xz` on `PATH`

#### Scenario: pycargoebuild required when cargo package selected

- **WHEN** the user runs `update dev-util/mise` and mise uses `DepsAndAssets Cargo` and needs work
- **THEN** preflight requires `pycargoebuild` and a supported fetcher (`wget` or `aria2c`) on `PATH` even if assets may be reusable

#### Scenario: Binary package skips language tools

- **WHEN** the user runs `update dev-util/grok-build-bin` and no `DepsAndAssets` package needs work
- **THEN** preflight does not fail solely because `go`, `npm`, `bun`, or `pycargoebuild` is missing from `PATH`

#### Scenario: Assets path required for deps packages

- **WHEN** the user runs `update` for a `DepsAndAssets` package that needs work and `assets-path` is unset
- **THEN** the program logs an error about the missing assets path and exits with status `1` before package mutation

#### Scenario: Bare update with only binary needs work skips go

- **WHEN** the user runs bare `update`, only a non-`DepsAndAssets` package needs work, and inventory still contains up-to-date Go packages
- **THEN** preflight does not fail solely because `go` is missing from `PATH`

#### Scenario: Reuse-only Go does not require go binary

- **WHEN** a Go `DepsAndAssets` package needs work only via the reuse path
- **THEN** preflight does not fail solely because `go` is missing from `PATH`

#### Scenario: Full-path cargo without aria2c soft-advises

- **WHEN** the user runs `update` and at least one cargo unit is classified full path, hard tools succeed with `wget` only, and `aria2c` is not on `PATH`
- **THEN** preflight does not hard-fail for missing `aria2c` and the run records the cargo wget/aria2 speed advisory in collected warnings
