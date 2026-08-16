## MODIFIED Requirements

### Requirement: Update plan phase before conditional assets preflight and disk gate

After spine tools (`git`, `ebuild`, `egencache`, `gpg`) and existing layout and manager-distfiles usability checks, and before conditional assets/language-tool hard requirements that depend on which packages need work, `update` SHALL run a **plan phase** over the selected package set that determines, for each package, whether it needs work, soft-skips, or hard-fails planning, using the same needs-work rules as outdated/apply (GitMv latest compare; `DepsAndAssets` runtime-lane plan plus local content and Manifest adequacy). The plan phase SHALL open and consult the check cache when enabled (and honor `--refresh`) before or as part of planning so valid entries avoid repeating upstream plan or latest network work. Plan concurrency SHALL use the effective package job limit (`--jobs`).

After the plan phase:

1. When at least one package that needs work will attempt `DepsAndAssets` apply, hard-require a resolvable GitHub token and configured `assets-path` git work tree, and prepare SSH when assets work requires it.
2. Classify reuse vs full for assets units that need heavy work (as defined by `disk-space-preflight`).
3. When at least one planned unit that needs work is classified **full path**, require `docker` on `PATH` and a usable product materialize image as specified by `hermetic-asset-materialize`. The program SHALL NOT require host `go`, `npm`, `bun`, `pycargoebuild`, fetchers, or `xz` on `PATH` solely because a unit is full path (those tools live in the image).
4. Run the disk-space feasibility gate on heavy units from packages that need work only.
5. Run the mutate/apply phase for the selection (soft-skips and successes as applicable). Packages already hard-failed in plan or classification SHALL NOT be re-planned or re-mutated; their hard-fail outcomes SHALL count toward the final exit status aggregation. The program SHALL still enter mutate/apply after a successful spine even when no package needs work (soft-skip presentation), and SHALL NOT use a special-case early exit solely because the needs-work set is empty.

#### Scenario: Plan runs before disk gate

- **WHEN** the user runs `update` with indicators and packages that require planning
- **THEN** needs-work determination completes before the disk-space feasibility gate runs

#### Scenario: Empty needs-work still enters apply

- **WHEN** the plan phase finds no package that needs work and the spine otherwise succeeds
- **THEN** the program still runs the apply/mutate phase (soft-skips) rather than exiting solely as a special empty case before apply

#### Scenario: Plan hard-fail not re-mutated

- **WHEN** classification hard-fails package `dev-util/crush` during plan and other packages need work
- **THEN** mutate does not re-attempt `dev-util/crush` and the crush hard-fail is included in final outcomes

### Requirement: Update preflight requires git ebuild and gpg

The `update` command SHALL verify that `git`, `ebuild`, `egencache`, and `gpg` are available on `PATH` before package mutation (spine tools). Spine tools SHALL be checked before the plan phase.

When at least one selected package **that needs work** will attempt a `DepsAndAssets` apply (including same-PV content/revision fixes), `update` SHALL additionally verify that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. When any such package will use the **full** materialize path, `docker` SHALL be on `PATH` and a usable product materialize image SHALL be available, as specified by `hermetic-asset-materialize`. Missing conditional hard requirements SHALL log an error and exit with status `1` before package mutation. When no package that needs work will attempt `DepsAndAssets`, the program SHALL NOT fail preflight solely because `docker`, assets path, or token are missing. Packages that only need the reuse path SHALL NOT require `docker` or host language tools (`go`/`npm`/`bun`/`pycargoebuild`) solely for that reuse work.

The program SHALL NOT require host `xz`, `go`, `npm`, `bun`, `pycargoebuild`, or cargo fetchers on `PATH` solely because a DepsAndAssets unit is full path. Host cargo wget/aria2 advisories SHALL NOT fire solely because those binaries are absent from the host `PATH` when full-path cargo runs in the image.

Conditional assets and Docker requirements that depend on needs-work or full vs reuse SHALL be evaluated **after** the plan phase (and after reuse/full classification for Docker), not solely from technique presence in the full selected inventory.

#### Scenario: Go tools required only when Go technique selected

- **WHEN** the user runs `update dev-util/crush` and crush will attempt full-path `DepsAndAssets` Go work
- **THEN** preflight requires `docker` on `PATH` and a usable materialize image and does not fail solely because host `go` is missing

#### Scenario: npm required for openspec full path

- **WHEN** the user runs `update dev-util/openspec` and openspec will attempt full-path npm cache construction
- **THEN** preflight requires `docker` and does not fail solely because host `npm` is missing

#### Scenario: bun required for ralph-tui full path

- **WHEN** the user runs `update dev-util/ralph-tui` and ralph-tui will attempt full-path bun cache construction
- **THEN** preflight requires `docker` and does not fail solely because host `bun` is missing

#### Scenario: bun required for opencode full path

- **WHEN** the user runs `update dev-util/opencode` and opencode will attempt full-path bun install-tree construction
- **THEN** preflight requires `docker` and does not fail solely because host `bun` is missing

#### Scenario: pycargoebuild required when cargo package selected

- **WHEN** the user runs `update dev-util/mise` and mise uses `DepsAndAssets Cargo` and needs work only via the reuse path
- **THEN** preflight does not fail solely because host `pycargoebuild` or a fetcher is missing

#### Scenario: Binary package skips language tools

- **WHEN** the user runs `update dev-util/grok-build-bin` and no `DepsAndAssets` package needs work
- **THEN** preflight does not fail solely because `docker` is missing from `PATH`

#### Scenario: Assets path required for deps packages

- **WHEN** the user runs `update` for a `DepsAndAssets` package that needs work and `assets-path` is unset
- **THEN** the program logs an error about the missing assets path and exits with status `1` before package mutation

#### Scenario: Bare update with only binary needs work skips go

- **WHEN** the user runs bare `update`, only a non-`DepsAndAssets` package needs work, and inventory still contains up-to-date Go packages
- **THEN** preflight does not fail solely because `docker` is missing from `PATH`

#### Scenario: Reuse-only Go does not require go binary

- **WHEN** a Go `DepsAndAssets` package needs work only via the reuse path
- **THEN** preflight does not fail solely because `docker` or host `go` is missing from `PATH`

#### Scenario: Full-path cargo without aria2c soft-advises

- **WHEN** the user runs `update` and at least one cargo unit is classified full path
- **THEN** preflight does not hard-fail for missing host `aria2c` and does not emit the host wget/aria2 speed advisory solely because those tools are absent from the host `PATH`

#### Scenario: Full-path cargo requires docker

- **WHEN** the user runs `update dev-util/mise` and a cargo unit is classified full path
- **THEN** preflight requires `docker` and a usable materialize image

