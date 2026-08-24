## ADDED Requirements

### Requirement: Overlay dirty preflight before update mutate

After the plan phase and before any overlay mutation or materialize `docker build`, `update` SHALL hard-fail with status `1` and SHALL NOT mutate overlay packages or start ensure `docker build` when `git status --porcelain` reports dirty, staged, untracked, or deleted paths under:

1. each **selected** package’s overlay directory, and
2. the overlay directory of each package atom this run’s materialize recipe will emerge from the overlay (today `dev-lang/bun-bin` when the recipe emerges `dev-lang/bun-bin::mndz`), even if that package is not in the `update` selection.

Unrelated overlay paths outside those directories SHALL NOT fail this preflight. Commands other than `update` SHALL NOT be required to run this preflight. The error SHALL name at least one dirty path or package directory and SHALL tell the operator to restore or finish that tree relative to git HEAD.

#### Scenario: Leftover bun-bin rename fails update dolt

- **WHEN** the operator runs `update dev-db/dolt`, overlay bun-bin has `bun-bin-1.3.14.ebuild` deleted and untracked `bun-bin-1.4.0.ebuild`, and ensure will emerge overlay bun-bin
- **THEN** the command exits `1` without mutating dolt and without `docker build`
- **AND** the error names `dev-lang/bun-bin` or a path under that directory

#### Scenario: Unrelated overlay file does not fail

- **WHEN** only `README.md` at the overlay root is dirty and selected package dirs and bun-bin are clean
- **THEN** this preflight does not fail solely because of that README

#### Scenario: Clean tree proceeds

- **WHEN** selected package dirs and ensure-emerge overlay atoms are clean vs HEAD
- **THEN** mutate and ensure are not blocked solely by this preflight

## MODIFIED Requirements

### Requirement: Update plan phase before conditional assets preflight and disk gate

After spine tools (`git`, `ebuild`, `egencache`, `gpg`) and existing layout and manager-distfiles usability checks, and before conditional assets/language-tool hard requirements that depend on which packages need work, `update` SHALL run a **plan phase** over the selected package set that determines, for each package, whether it needs work, soft-skips, or hard-fails planning, using the same needs-work rules as outdated/apply (GitMv latest compare; `DepsAndAssets` runtime-lane plan plus local content and Manifest adequacy). When an overlay wait-edge provider is selected and needs work, selected consumers SHALL use the hypothetical working plan specified by `overlay-apply-waves`. The plan phase SHALL open and consult the check cache when enabled (and honor `--refresh`) before or as part of planning so valid entries avoid repeating upstream plan or latest network work; deps plans computed under hypothetical overlay ceilings SHALL NOT be stored, as specified by `check-cache`. Plan concurrency SHALL use the effective package job limit (`--jobs`). Overlay wait-edge refuse, plan-delta, and fail-closed provider-fetch outcomes specified by `overlay-apply-waves` SHALL be recorded as plan hard-fails for those consumers.

After the plan phase:

1. Run the overlay dirty preflight specified above.
2. When at least one package that needs work **and is admissible** (not withheld on an overlay wait-edge provider that still needs work) will attempt `DepsAndAssets` apply, hard-require a resolvable GitHub token and configured `assets-path` git work tree, and prepare SSH when assets work requires it. When overlay wait-edge consumers are withheld but their hypothetical working plan needs assets, the program MAY require token and `assets-path` at this time.
3. Classify reuse vs full for assets units that need heavy work among **admitted** packages **and** among withheld consumers that have a hypothetical working plan (so t0 ensure floors include those full-path units), as defined by `disk-space-preflight` and `ensure-materialize-image`.
4. When at least one planned unit that needs work (admitted or withheld hypo-planned) is classified **full path**, require `docker` on `PATH`. The program SHALL NOT require host `go`, `npm`, `bun`, `pycargoebuild`, fetchers, or `xz` on `PATH` solely because a unit is full path (those tools live in the image). Ensure of the materialize image SHALL follow `ensure-materialize-image`: independent GitMv and reuse MAY enter mutate without waiting on ensure; overlay bun-bin file work SHALL complete before a bun-layer `docker build`; full-path language materialize SHALL wait on successful ensure and on overlay wait-edge signed commit as specified by `overlay-apply-waves`, and SHALL NOT occupy a package job while waiting.
5. Run the disk-space feasibility gate on heavy units from admitted packages that need work and from withheld hypo-planned consumers that need work, and the image-build free-space check when ensure will `docker build`, as specified by `disk-space-preflight` and `ensure-materialize-image`.
6. Run the mutate/apply phase for **admitted** packages (soft-skips and successes as applicable). Packages withheld per `overlay-apply-waves` SHALL NOT be mutated until the provider’s signed overlay commit. Full-path admitted packages SHALL NOT start container materialize until ensure has succeeded. Packages already hard-failed in plan or classification SHALL NOT be re-planned or re-mutated; their hard-fail outcomes SHALL count toward the final exit status aggregation. The program SHALL still enter mutate/apply after a successful spine even when no package needs work (soft-skip presentation), and SHALL NOT use a special-case early exit solely because the needs-work set is empty.

When an overlay wait-edge provider later succeeds with a signed overlay commit, the program SHALL admit withheld consumers using their hypothetical working plans as specified by `overlay-apply-waves`, then evaluate conditional token/assets/docker-on-PATH and the disk-space gate for those consumers’ needs-work units before admitting them to language materialize. The program SHALL NOT rediscover overlay ceilings and re-plan those consumers from disk solely because the provider committed. A conditional-preflight, ensure, or disk-gate failure at that admit SHALL hard-fail the affected consumers and SHALL NOT roll back already-committed overlay units.

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

- **WHEN** bun-bin has committed successfully, ralph-tui’s hypothetical plan needs full-path work, and docker is missing at admit
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains

#### Scenario: GitMv starts while image is ensured

- **WHEN** grok-build-bin and a full-path Go package both need work and the materialize image is missing
- **THEN** grok-build-bin may mutate while ensure runs
- **AND** the Go package does not start container materialize until ensure succeeds
