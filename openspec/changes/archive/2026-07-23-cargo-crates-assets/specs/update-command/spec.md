## MODIFIED Requirements

### Requirement: Update preflight requires git ebuild and gpg

The `update` command SHALL verify that `git`, `ebuild`, `egencache`, and `gpg` are available on `PATH` before package mutation (existing spine tools).

When at least one selected package will attempt a `DepsAndAssets` apply (including same-PV content/revision fixes), `update` SHALL additionally verify that `xz` is available on `PATH`, that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. When any such package will use the **full** materialize path for ecosystem `Go`, `go` SHALL be on `PATH`. When any will use the full path for ecosystem `Npm`, `npm` SHALL be on `PATH`. When any will use the full path for ecosystem `Bun`, `bun` SHALL be on `PATH`. When any selected package uses ecosystem `Cargo` (including when all units may later reuse assets), `pycargoebuild` SHALL be on `PATH` and at least one of `wget` or `aria2c`/`aria2` SHALL be on `PATH`. Missing conditional requirements SHALL log an error and exit with status `1` before package mutation. When no selected package needs `DepsAndAssets`, the program SHALL NOT fail preflight solely because `go`, `npm`, `bun`, `pycargoebuild`, fetchers, `xz`, assets path, or token are missing. Packages that only need the reuse path SHALL NOT require the language tool (`go`/`npm`/`bun`) solely for that reuse work; Cargo still requires `pycargoebuild` and a fetcher in preflight whenever any cargo `DepsAndAssets` package is selected (P1).

#### Scenario: Go tools required only when Go technique selected

- **WHEN** the user runs `update dev-util/crush` and crush will attempt full-path `DepsAndAssets` Go work
- **THEN** preflight requires `go` and `xz` on `PATH`

#### Scenario: npm required for openspec full path

- **WHEN** the user runs `update dev-util/openspec` and openspec will attempt full-path npm cache construction
- **THEN** preflight requires `npm` and `xz` on `PATH`

#### Scenario: bun required for ralph-tui full path

- **WHEN** the user runs `update dev-util/ralph-tui` and ralph-tui will attempt full-path bun cache construction
- **THEN** preflight requires `bun` and `xz` on `PATH`

#### Scenario: pycargoebuild required when cargo package selected

- **WHEN** the user runs `update dev-util/mise` and mise uses `DepsAndAssets Cargo`
- **THEN** preflight requires `pycargoebuild` and a supported fetcher on `PATH` even if assets may be reusable

#### Scenario: Binary package skips language tools

- **WHEN** the user runs `update dev-util/opencode-bin` and no `DepsAndAssets` package is selected
- **THEN** preflight does not fail solely because `go`, `npm`, `bun`, or `pycargoebuild` is missing from `PATH`

#### Scenario: Assets path required for deps packages

- **WHEN** the user runs `update` for a `DepsAndAssets` package and `assets-path` is unset
- **THEN** the program logs an error about the missing assets path and exits with status `1` before package mutation
