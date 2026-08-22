## MODIFIED Requirements

### Requirement: Update plan phase before conditional assets preflight and disk gate

After spine tools (`git`, `ebuild`, `egencache`, `gpg`) and existing layout and manager-distfiles usability checks, and before conditional assets/language-tool hard requirements that depend on which packages need work, `update` SHALL run a **plan phase** over the selected package set that determines, for each package, whether it needs work, soft-skips, or hard-fails planning, using the same needs-work rules as outdated/apply (GitMv latest compare; `DepsAndAssets` runtime-lane plan plus local content and Manifest adequacy). The plan phase SHALL open and consult the check cache when enabled (and honor `--refresh`) before or as part of planning so valid entries avoid repeating upstream plan or latest network work. Plan concurrency SHALL use the effective package job limit (`--jobs`). Overlay wait-edge refuse, plan-delta, and fail-closed provider-fetch outcomes specified by `overlay-apply-waves` SHALL be recorded as plan hard-fails for those consumers.

After the plan phase:

1. When at least one package that needs work **and is admissible** (not withheld on an overlay wait-edge provider that still needs work) will attempt `DepsAndAssets` apply, hard-require a resolvable GitHub token and configured `assets-path` git work tree, and prepare SSH when assets work requires it.
2. Classify reuse vs full for assets units that need heavy work among **admitted** packages (as defined by `disk-space-preflight`).
3. When at least one planned unit that needs work and is admitted is classified **full path**, require `docker` on `PATH` and a usable product materialize image as specified by `hermetic-asset-materialize`. The program SHALL NOT require host `go`, `npm`, `bun`, `pycargoebuild`, fetchers, or `xz` on `PATH` solely because a unit is full path (those tools live in the image).
4. Run the disk-space feasibility gate on heavy units from admitted packages that need work only.
5. Run the mutate/apply phase for **admitted** packages (soft-skips and successes as applicable). Packages withheld per `overlay-apply-waves` SHALL NOT be mutated on the initial plan. Packages already hard-failed in plan or classification SHALL NOT be re-planned or re-mutated; their hard-fail outcomes SHALL count toward the final exit status aggregation. The program SHALL still enter mutate/apply after a successful spine even when no package needs work (soft-skip presentation), and SHALL NOT use a special-case early exit solely because the needs-work set is empty.

When an overlay wait-edge provider later succeeds with a signed overlay commit, the program SHALL re-plan withheld consumers as specified by `overlay-apply-waves`, then repeat classify, conditional token/assets/docker preflight, and the disk-space gate for **new** needs-work units from those consumers before admitting them. A conditional-preflight or disk-gate failure at that re-entry SHALL hard-fail the affected consumers and SHALL NOT roll back already-committed overlay units.

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
- **THEN** mutate does not apply ralph-tui until after bun-bin’s signed overlay commit and ralph-tui re-plan

#### Scenario: Post-provider re-entry does not roll back bun-bin

- **WHEN** bun-bin has committed successfully, ralph-tui re-plan needs full-path work, and docker is missing at re-entry
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains
