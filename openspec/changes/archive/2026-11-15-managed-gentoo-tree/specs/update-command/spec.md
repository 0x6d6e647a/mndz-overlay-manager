# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: Update preflight requires git ebuild and gpg`
- TO: `### Requirement: Update preflight requires git gpg and docker`

## MODIFIED Requirements

### Requirement: Update plan phase before conditional assets preflight and disk gate

After spine tools (`git`, `gpg`, `docker`), existing layout and manager-distfiles usability checks, and the managed Gentoo tree sync specified by `gentoo-tree`, and before conditional assets/language-tool hard requirements that depend on which packages need work, `update` SHALL run a **plan phase** over the selected package set that determines, for each package, whether it needs work, soft-skips, or hard-fails planning, using the same needs-work rules as outdated/apply (GitMv latest compare; `DepsAndAssets` runtime-lane plan plus local content and Manifest adequacy). When an overlay wait-edge provider is selected and needs work, selected consumers SHALL use the hypothetical working plan specified by `overlay-apply-waves`. The plan phase SHALL open and consult the check cache when enabled (and honor `--refresh`) before or as part of planning so valid entries avoid repeating upstream plan or latest network work; deps plans computed under hypothetical overlay ceilings SHALL NOT be stored, as specified by `check-cache`. Plan concurrency SHALL use the effective package job limit (`--jobs`). Overlay wait-edge refuse, plan-delta, and fail-closed provider-fetch outcomes specified by `overlay-apply-waves` SHALL be recorded as plan hard-fails for those consumers.

After the plan phase:

1. Run the overlay dirty preflight specified above.
2. When at least one package that needs work **and is admissible** (not withheld on an overlay wait-edge provider that still needs work) will attempt `DepsAndAssets` apply, hard-require a resolvable GitHub token and configured `assets-path` git work tree, and prepare SSH when assets work requires it. When overlay wait-edge consumers are withheld but their hypothetical working plan needs assets, the program MAY require token and `assets-path` at this time.
3. Classify reuse vs full for assets units that need heavy work among **admitted** packages **and** among withheld consumers that have a hypothetical working plan (so t0 ensure floors include those full-path units), as defined by `disk-space-preflight` and `ensure-materialize-image`.
4. When at least one planned unit that needs work (admitted or withheld hypo-planned) is classified **full path**, require a materialize image that provides its toolchains. The program SHALL NOT require host `go`, `npm`, `bun`, `pycargoebuild`, fetchers, or `xz` on `PATH` solely because a unit is full path (those tools live in the image). Ensure of the materialize image SHALL follow `ensure-materialize-image`: independent GitMv and reuse MAY enter mutate without waiting on ensure; overlay bun-bin file work SHALL complete before a bun-layer `docker build`; full-path language materialize SHALL wait on successful ensure and on overlay wait-edge signed commit as specified by `overlay-apply-waves`, and SHALL NOT occupy a package job while waiting.
5. Run the disk-space feasibility gate on heavy units from admitted packages that need work and from withheld hypo-planned consumers that need work, and the image-build free-space check when ensure will `docker build`, as specified by `disk-space-preflight` and `ensure-materialize-image`.
6. Run the mutate/apply phase for **admitted** packages (soft-skips and successes as applicable). Packages withheld per `overlay-apply-waves` SHALL NOT be mutated until the provider’s signed overlay commit. Full-path admitted packages SHALL NOT start container materialize until ensure has succeeded. Packages already hard-failed in plan or classification SHALL NOT be re-planned or re-mutated; their hard-fail outcomes SHALL count toward the final exit status aggregation. The program SHALL still enter mutate/apply after a successful spine even when no package needs work (soft-skip presentation), and SHALL NOT use a special-case early exit solely because the needs-work set is empty.

When an overlay wait-edge provider later succeeds with a signed overlay commit, the program SHALL admit withheld consumers using their hypothetical working plans as specified by `overlay-apply-waves`, then evaluate conditional token/assets/materialize-image requirements and the disk-space gate for those consumers’ needs-work units before admitting them to language materialize. The program SHALL NOT rediscover overlay ceilings and re-plan those consumers from disk solely because the provider committed. A conditional-preflight, ensure, or disk-gate failure at that admit SHALL hard-fail the affected consumers and SHALL NOT roll back already-committed overlay units.

#### Scenario: Plan runs before disk gate

- **WHEN** the user runs `update` with indicators and packages that require planning
- **THEN** needs-work determination completes before the disk-space feasibility gate runs

#### Scenario: Empty needs-work still enters apply

- **WHEN** the plan phase finds no package that needs work and the spine otherwise succeeds
- **THEN** the program still runs the apply/mutate phase (soft-skips) rather than exiting solely as a special empty case before apply

#### Scenario: Plan hard-fail not re-mutated

- **WHEN** classification hard-fails package `dev-util/crush` during plan and other packages need work
- **THEN** mutate does not re-attempt `dev-util/crush` and the crush hard-fail is included in final outcomes

#### Scenario: Withheld consumer not mutated on initial plan

- **WHEN** bun-bin needs work and ralph-tui is withheld on bun-bin
- **THEN** mutate does not apply ralph-tui until after bun-bin’s signed overlay commit
- **AND** ralph-tui is not disk-re-planned solely because bun-bin committed

#### Scenario: Post-provider re-entry does not roll back bun-bin

- **WHEN** bun-bin has committed successfully, ralph-tui’s hypothetical plan needs full-path work, and ensure fails at admit
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains

#### Scenario: GitMv starts while image is ensured

- **WHEN** grok-build-bin and a full-path Go package both need work and the materialize image is missing
- **THEN** grok-build-bin may mutate while ensure runs
- **AND** the Go package does not start container materialize until ensure succeeds

### Requirement: Update preflight requires git gpg and docker

The `update` command SHALL verify that `git`, `gpg`, and `docker` are available on `PATH` before package mutation (spine tools). It SHALL NOT require host `ebuild` or `egencache`; those run in the Portage tools container specified by `portage-tools-container`. Spine tools SHALL be checked before the plan phase.

When at least one selected package **that needs work** will attempt a `DepsAndAssets` apply (including same-PV content/revision fixes), `update` SHALL additionally verify that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. When any such package will use the **full** materialize path, a usable product materialize image providing its toolchains SHALL be available as specified by `hermetic-asset-materialize` and `ensure-materialize-image` (ensure for the default tag; inspect-only for `MNDZ_MATERIALIZE_IMAGE`). Missing conditional hard requirements SHALL log an error and fail with status `1` before those units’ mutation (spine-wide before mutate has started; per-consumer at overlay wait-edge re-entry). When no package that needs work will attempt `DepsAndAssets`, the program SHALL NOT fail preflight solely because a toolchain materialize image, assets path, or token are missing. Packages that only need the reuse path SHALL NOT require toolchains in the materialize image or host language tools (`go`/`npm`/`bun`/`pycargoebuild`) solely for that reuse work.

The program SHALL NOT require host `xz`, `go`, `npm`, `bun`, `pycargoebuild`, or cargo fetchers on `PATH` solely because a DepsAndAssets unit is full path. Host cargo wget/aria2 advisories SHALL NOT fire solely because those binaries are absent from the host `PATH` when full-path cargo runs in the image.

Conditional assets and materialize-image requirements that depend on needs-work or full vs reuse SHALL be evaluated **after** the plan phase (and after reuse/full classification for the materialize image), not solely from technique presence in the full selected inventory. Docker image **ensure** SHALL NOT block GitMv or reuse mutate.

#### Scenario: Go tools required only when Go technique selected

- **WHEN** the user runs `update dev-util/crush` and crush will attempt full-path `DepsAndAssets` Go work
- **THEN** preflight requires `docker` on `PATH` and a usable materialize image (ensured if the default tag is used) and does not fail solely because host `go` is missing

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
- **THEN** preflight does not require toolchains in the materialize image

#### Scenario: Assets path required for deps packages

- **WHEN** the user runs `update` for a `DepsAndAssets` package that needs work and `assets-path` is unset
- **THEN** the program logs an error about the missing assets path and exits with status `1` before package mutation

#### Scenario: Bare update with only binary needs work skips go

- **WHEN** the user runs bare `update`, only a non-`DepsAndAssets` package needs work, and inventory still contains up-to-date Go packages
- **THEN** preflight does not require Go in the materialize image

#### Scenario: Reuse-only Go does not require go binary

- **WHEN** a Go `DepsAndAssets` package needs work only via the reuse path
- **THEN** preflight does not require Go in the materialize image or host `go` on `PATH`

#### Scenario: Full-path cargo without aria2c soft-advises

- **WHEN** the user runs `update` and at least one cargo unit is classified full path
- **THEN** preflight does not hard-fail for missing host `aria2c` and does not emit the host wget/aria2 speed advisory solely because those tools are absent from the host `PATH`

#### Scenario: Full-path cargo requires docker

- **WHEN** the user runs `update dev-util/mise` and a cargo unit is classified full path
- **THEN** preflight requires `docker` and a usable materialize image

#### Scenario: Missing docker fails the spine

- **WHEN** the user runs `update` and `docker` is not on `PATH`
- **THEN** the program logs an error naming `docker` and exits with status `1` before the plan phase

#### Scenario: Host Portage tools not required

- **WHEN** the user runs `update` on a host without `ebuild` or `egencache` and `git`, `gpg`, and `docker` are on `PATH`
- **THEN** spine preflight does not fail because `ebuild` or `egencache` is missing

### Requirement: Update refresh flag

The `update` subcommand SHALL accept a `--refresh` flag that forces live upstream latest fetch and deps plan work for packages that need that work, ignoring existing cache entries for reads, and SHALL write fresh eligible entries when the cache is enabled. `--refresh` SHALL also force a managed Gentoo tree sync before planning, regardless of the tree's age, as specified by `gentoo-tree`.

#### Scenario: Update refresh forces live fetch

- **WHEN** the user runs `update --refresh` for a package with a valid latest cache entry
- **THEN** the program performs a live latest-version fetch (or live plan for deps) rather than using the existing entry for reads

#### Scenario: Update refresh syncs the tree

- **WHEN** the user runs `update --refresh` and the managed tree was synced ten minutes ago
- **THEN** the program syncs the tree before the plan phase
