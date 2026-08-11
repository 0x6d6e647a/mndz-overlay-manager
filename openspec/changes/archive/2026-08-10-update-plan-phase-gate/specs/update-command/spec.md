## ADDED Requirements

### Requirement: Update plan phase before conditional assets preflight and disk gate

After spine tools (`git`, `ebuild`, `egencache`, `gpg`) and existing layout and manager-distfiles usability checks, and before conditional assets/language-tool hard requirements that depend on which packages need work, `update` SHALL run a **plan phase** over the selected package set that determines, for each package, whether it needs work, soft-skips, or hard-fails planning, using the same needs-work rules as outdated/apply (GitMv latest compare; `DepsAndAssets` runtime-lane plan plus local content and Manifest adequacy). The plan phase SHALL open and consult the check cache when enabled (and honor `--refresh`) before or as part of planning so valid entries avoid repeating upstream plan or latest network work. Plan concurrency SHALL use the effective package job limit (`--jobs`).

After the plan phase:

1. When at least one package that needs work will attempt `DepsAndAssets` apply, hard-require `xz`, resolvable GitHub token, and configured `assets-path` git work tree, and prepare SSH when assets work requires it.
2. Classify reuse vs full for assets units that need heavy work (as defined by `disk-space-preflight`).
3. Require language tools (`go` / `npm` / `bun`) only when at least one planned unit that needs work is classified **full path** for that ecosystem; require `pycargoebuild` and a fetcher when any **cargo** package needs work (including when all cargo units may reuse assets).
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

## MODIFIED Requirements

### Requirement: Update preflight requires git ebuild and gpg

The `update` command SHALL verify that `git`, `ebuild`, `egencache`, and `gpg` are available on `PATH` before package mutation (spine tools). Spine tools SHALL be checked before the plan phase.

When at least one selected package **that needs work** will attempt a `DepsAndAssets` apply (including same-PV content/revision fixes), `update` SHALL additionally verify that `xz` is available on `PATH`, that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. When any such package will use the **full** materialize path for ecosystem `Go`, `go` SHALL be on `PATH`. When any will use the full path for ecosystem `Npm`, `npm` SHALL be on `PATH`. When any will use the full path for ecosystem `Bun`, `bun` SHALL be on `PATH`. When any package that **needs work** uses ecosystem `Cargo` (including when all units may later reuse assets), `pycargoebuild` SHALL be on `PATH` and at least one of `wget` or `aria2c`/`aria2` SHALL be on `PATH`. Missing conditional requirements SHALL log an error and exit with status `1` before package mutation. When no package that needs work will attempt `DepsAndAssets`, the program SHALL NOT fail preflight solely because `go`, `npm`, `bun`, `pycargoebuild`, fetchers, `xz`, assets path, or token are missing. Packages that only need the reuse path SHALL NOT require the language tool (`go`/`npm`/`bun`) solely for that reuse work; Cargo still requires `pycargoebuild` and a fetcher in preflight whenever any cargo `DepsAndAssets` package **needs work** (P1).

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
- **THEN** preflight requires `pycargoebuild` and a supported fetcher on `PATH` even if assets may be reusable

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

### Requirement: Update runs disk-space feasibility before package mutation

After the plan phase, conditional assets/language preflight, and reuse/full classification succeed as applicable, and before concurrent per-package mutation that can open heavy temporary trees or fetch distfiles, `update` SHALL run the disk-space feasibility gate defined by `disk-space-preflight` for the **heavy units of packages that need work** only (not the full selected inventory). Failure of that gate SHALL log an error and exit with status `1` without applying package updates. When activity indicators are enabled, the preflight progress presentation SHALL include a step covering disk-space evaluation (either as its own step or clearly part of sequential preflight after plan).

#### Scenario: Insufficient free space blocks update

- **WHEN** the user runs `update` for packages that need full-path materialize and free space on the effective temp root is below the concurrent sum required by `disk-space-preflight`
- **THEN** the program logs an actionable free-space error and exits with status `1` before package mutation

#### Scenario: Sufficient free space allows package work

- **WHEN** the user runs `update` with tools and distfiles probe ok and free space satisfies max and concurrent-sum needs on hard-check filesystems for needs-work units
- **THEN** the program proceeds to per-package update work

#### Scenario: No heavy write units skips hard gate failure

- **WHEN** packages that need work require no heavy temp materialize and no manager distfiles fetch that requires additional free space under `disk-space-preflight` estimation
- **THEN** the program does not hard-fail solely for low temp free space that would only matter for full materialize of packages that do not need work

#### Scenario: Free space enough for needs-work only

- **WHEN** free space is sufficient for the single package that needs heavy work but would be insufficient if every `DepsAndAssets` inventory package were estimated as full-path concurrently under the effective `--jobs`
- **THEN** the disk-space gate passes and mutate proceeds for the needs-work set

### Requirement: Update uses check cache

The `update` command SHALL open the shared check cache (when enabled) **before** the plan phase and SHALL consult it during plan (and mutate when applicable) for packages that perform latest-version fetch or runtime-lane planning when `--refresh` was not passed. On a valid hit, plan SHALL use the cached remote PV or runtime-lane plan without repeating that network work. After successful live fetch or plan during plan or apply, and after successful package apply when rewriting is required, the command SHALL store or rewrite eligible entries when the cache is enabled. The command SHALL emit exactly one check-cache hit/fetch info summary at the end of the run as specified by `check-cache`. Functional soft-skip and hard-fail rules for packages SHALL remain unchanged aside from the source of remote or plan data and the plan-before-mutate structure.

#### Scenario: Outdated then update reuses plan

- **WHEN** the user runs `outdated` and then `update` within the effective TTL without `--refresh` and without local fingerprint changes for a package that was checked
- **THEN** `update` may plan and apply that package using cached remote or plan data without repeating the corresponding upstream discovery network work

#### Scenario: Update stores on live plan

- **WHEN** `update` performs a live deps plan because of a cache miss and the plan succeeds
- **THEN** an eligible deps cache entry is stored when the cache is enabled
