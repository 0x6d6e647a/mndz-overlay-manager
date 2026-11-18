# update-smoke-gate Specification

## Purpose

Smoke-test every `update` unit before anything about it is published or committed, so only ebuilds that install and pass their checks reach the overlay history and the assets repository.

## Requirements

### Requirement: Every unit that needs work passes a gate before publishing

Each `update` unit that needs work, whether `GitMvAndManifest` or `DepsAndAssets` (full or reuse path), SHALL pass a smoke gate before its assets sidecars are written, before any assets commit, push, or release, and before its signed overlay commit. There SHALL be no option that skips the gate. A unit that does not pass SHALL hard-fail.

#### Scenario: GitMv unit is gated

- **WHEN** `update` renames `deno-bin-2.9.2.ebuild` to `deno-bin-2.9.3.ebuild` and regenerates its Manifest and md5-cache
- **THEN** no overlay commit for `dev-lang/deno-bin: 2.9.3` exists until the gate for `dev-lang/deno-bin-2.9.3` has passed

#### Scenario: Full-path unit publishes nothing before the gate

- **WHEN** a full-path unit for `dev-util/hk-2.13.0` has built `hk-2.13.0-crates.tar.xz` and its gate fails
- **THEN** no sidecar, assets commit, assets push, or GitHub release exists for `hk-2.13.0`

#### Scenario: Reuse-path unit is gated

- **WHEN** a unit takes the reuse path for an existing release
- **THEN** its overlay commit is created only after its gate passes

### Requirement: Gate order within a unit

For each unit the order SHALL be:

1. materialize or rename;
2. ebuild write, `ebuild … manifest`, and package `egencache`;
3. gate;
4. assets publish, when the unit publishes;
5. verification of the published assets, as specified by `assets-publish`;
6. signed overlay commit;
7. overlay push, as specified by `overlay-push`.

A unit SHALL NOT reach a later step after an earlier one failed.

#### Scenario: Manifest precedes publish

- **WHEN** a full-path unit runs
- **THEN** its Manifest is regenerated from the locally built distfile before any assets commit for that unit

#### Scenario: Gate failure stops the unit

- **WHEN** a unit's gate fails
- **THEN** the unit performs no assets publish, verification, overlay commit, or overlay push

### Requirement: Gate runs are the new PV per lane ceiling

A gate SHALL consist of the smoke runs that the `smoke` command would plan for the unit's PV alone. That is one run per distinct lane ceiling the PV serves, or one run when it serves no lane, with the checks of the package's smoke definition. Other on-disk versions SHALL NOT be run. The gate passes only when every one of its runs passes.

#### Scenario: Two lane ceilings

- **WHEN** the unit's PV `dev-util/beads-1.3.5` serves the plain Go lane (ceiling `1.26.11`) and the tilde lane (ceiling `1.27.4`)
- **THEN** the gate runs `dev-util/beads-1.3.5` twice, once per ceiling, and passes only if both pass

#### Scenario: Older versions are not run

- **WHEN** `dev-util/beads-1.0.4` is also on disk
- **THEN** the gate does not run `1.0.4`

### Requirement: Gate runs see HEAD plus the unit's own changes

Each gated run SHALL see an overlay made of the overlay's `HEAD` commit plus only the gated unit's own changes, mounted read-only. These are the package directory and that package's md5-cache entries. Uncommitted changes of other units, and any other worktree changes, SHALL NOT be visible.

#### Scenario: Concurrent unit is invisible

- **WHEN** unit A is gated while unit B of another package has renamed its ebuild but not committed
- **THEN** A's run sees B's package as it is at `HEAD`

#### Scenario: Earlier committed unit is visible

- **WHEN** unit B committed before unit A's gate starts
- **THEN** A's run sees B's committed ebuild

### Requirement: Staged distfiles are served to gated runs

Distfiles that the unit built and has not yet published SHALL be staged for its gated runs in a read-only location that holds only that unit's distfiles. When Portage fetches a URL under the assets repository's release download prefix and the file is staged, the fetch SHALL deliver the staged file. Portage SHALL verify it against the unit's Manifest as for any fetch.

#### Scenario: Unpublished crates tarball

- **WHEN** the gated ebuild's `SRC_URI` names `https://github.com/<owner>/<assets-repo>/releases/download/hk-2.13.0/hk-2.13.0-crates.tar.xz` and that file is staged
- **THEN** the package step obtains that file without contacting GitHub

#### Scenario: Staged file differs from the Manifest

- **WHEN** a staged file's hashes do not match the unit's Manifest
- **THEN** the run fails in the package step

### Requirement: Unstaged assets URLs fail the fetch

In a gated run, a fetch of a URL under the assets repository's release download prefix whose file is not staged for the unit SHALL fail with an error naming the URL. It SHALL NOT fall back to the network. URLs outside that prefix SHALL be fetched over the network as in a standalone `smoke` run.

#### Scenario: Misnamed asset

- **WHEN** the ebuild names `hk-2.13.0-crate.tar.xz` but the unit staged `hk-2.13.0-crates.tar.xz`
- **THEN** the run fails in the package step and its log names the unstaged URL

#### Scenario: Upstream archive

- **WHEN** the ebuild also names an upstream `https://github.com/<upstream>/hk/archive/v2.13.0.tar.gz`
- **THEN** that file is downloaded from the network

#### Scenario: Reuse path fetches the real release

- **WHEN** a reuse-path unit is gated
- **THEN** nothing is staged and its assets distfiles are downloaded from the published release

### Requirement: Gated runs go through one smoke lane

At most one gated run SHALL be active at a time in an `update` command. Units SHALL be served in the order their gates became ready. A unit waiting for the smoke lane SHALL NOT hold a package job slot. Materialize and other phase-1 work of other units MAY continue while a gated run is active.

#### Scenario: Two units ready together

- **WHEN** two units reach their gates at the same time
- **THEN** one unit's runs complete before the other's first run starts

#### Scenario: Materialize overlaps a gate

- **WHEN** one unit's gated run is active and another admitted unit is materializing
- **THEN** the materialize continues

### Requirement: Gates wait for overlay dependencies updated in the same run

A unit's gate SHALL wait while any other package that is selected in this run, still has work in progress, and is named by an atom in the `DEPEND`, `BDEPEND`, `RDEPEND`, `IDEPEND`, or `PDEPEND` of the unit's rewritten ebuild. Work in progress means not yet committed, failed, held, or soft-skipped. Only the gate waits; earlier steps SHALL NOT. A waiting unit SHALL NOT hold a package job slot or the smoke lane.

#### Scenario: Dependent waits at its gate

- **WHEN** `update codex codex-acp` runs and `codex-acp`'s rewritten ebuild depends on `dev-util/codex`
- **THEN** `codex-acp` may build its crates tarball while `codex` builds
- **AND** `codex-acp`'s gate does not start until `codex` has committed or failed

#### Scenario: Unselected dependency does not wait

- **WHEN** `update codex-acp` runs without `codex` selected
- **THEN** `codex-acp`'s gate does not wait on `codex`

### Requirement: Gate after a dependency's outcome uses HEAD

After a dependency reaches an outcome, the waiting unit's gate SHALL run against the snapshot specified for gated runs. When the dependency committed, the snapshot includes its new ebuild. When the dependency failed or was held, the snapshot includes the version at `HEAD`. The dependent SHALL NOT fail solely because its dependency failed.

#### Scenario: Dependency fails its gate

- **WHEN** `codex-0.164.0` fails its gate and `codex-acp-2.7.0` depends on `dev-util/codex` without a version bound
- **THEN** `codex-acp-2.7.0` is gated against `codex-0.163.0` from `HEAD`
- **AND** it may pass, publish, and commit

#### Scenario: Version bound on the failed dependency

- **WHEN** `codex-0.164.0` fails its gate and `codex-acp-2.7.0` requires `>=dev-util/codex-0.164.0`
- **THEN** `codex-acp-2.7.0`'s gate fails in its dependencies stage

### Requirement: Dependency cycles fail at the gate

When gate waits between units form a cycle, every unit in the cycle SHALL hard-fail with a message that names every package in the cycle. Units outside the cycle SHALL continue.

#### Scenario: Two-package cycle

- **WHEN** selected `A`'s rewritten ebuild depends on selected `B` and `B`'s depends on `A`
- **THEN** both units hard-fail naming `A` and `B`
- **AND** neither is published or committed

### Requirement: Ebuild not keyworded for the host fails the gate

When the unit's PV would be skipped by `smoke` because its `KEYWORDS` lack the host architecture, the gate SHALL fail. The message SHALL name the missing keyword.

#### Scenario: amd64-only package on arm64

- **WHEN** the host is arm64 and `dev-util/codex-0.164.0` has `KEYWORDS="-* ~amd64"`
- **THEN** its gate fails naming `arm64`
- **AND** nothing for that unit is published or committed

### Requirement: Gate failures are final within the command

A failed gated run SHALL NOT be retried in the same `update` command, including when it failed in its dependencies stage or because storage was exhausted. `update` SHALL NOT estimate or reserve free space for gated builds.

#### Scenario: Mirror timeout in dependencies

- **WHEN** a gated run fails in its dependencies stage because a mirror timed out
- **THEN** the gate fails and no second attempt is made

#### Scenario: Storage exhausted

- **WHEN** a gated run's package step fails because container storage is full
- **THEN** the gate fails and other units continue

### Requirement: Gate prerequisites are set up only when work exists

When at least one unit needs work, `update` SHALL verify the smoke prerequisites before any overlay mutation or materialize `docker build`. These are Docker 28.0 or newer and the containerd image store. Failure SHALL exit with status `1` naming what is missing. When no unit needs work, `update` SHALL NOT check them, build the smoke image, or take a tree snapshot.

#### Scenario: Old engine with work

- **WHEN** a package needs work and the Docker engine reports version `27.5.1`
- **THEN** `update` exits with status `1` naming `28.0` before mutating any package

#### Scenario: Nothing to do

- **WHEN** no selected package needs work
- **THEN** `update` neither inspects the Docker engine version for smoke nor builds the smoke image

### Requirement: Smoke image, snapshot, and probe are ready before the first gate

When at least one unit needs work, `update` SHALL ensure the smoke image, take one tree snapshot for the command, and run the sandbox probe, as specified by `smoke-image` and `smoke-environment`. This MAY overlap materialize image ensure and phase-1 work, and SHALL complete before the first gated run. On failure, units not yet started SHALL NOT start. Units already in progress SHALL hard-fail.

#### Scenario: Probe fails mid-run

- **WHEN** the sandbox probe fails while a GitMv unit has already renamed its ebuild
- **THEN** that unit hard-fails without being committed and no further unit starts
- **AND** the command exits with status `1`

### Requirement: Gate runs use the smoke definitions and environment

Each gated run SHALL use the container environment, checks, extra atoms, keywords, USE settings, network rules, and compile cache that a `smoke` run of the same ebuild and lane would use. The exceptions are the overlay view and fetch behavior this capability specifies.

#### Scenario: Same checks as smoke

- **WHEN** a unit for `dev-util/hk` is gated
- **THEN** its runs execute the checks of `dev-util/hk`'s smoke definition

### Requirement: Gate results are reported and logged

The package row SHALL show the gate as its own step. Each gated run's output SHALL be written under the smoke run-log directory for the `update` run id, as for `smoke`. A gate failure SHALL be logged as an error naming the run, its `fail: <stage>` or skip reason, and the log path. Success stdout lines SHALL NOT change.

#### Scenario: Failure names its log

- **WHEN** a gated run of `dev-util/hk-2.13.0` fails in check `version`
- **THEN** the logged error names `fail: check version` and a file under `smoke/logs/<run-id>/`

### Requirement: Wait-edge providers are gated before admitting consumers

An overlay wait-edge provider's unit SHALL pass its gate before its signed overlay commit. Withheld consumers SHALL be admitted after that commit, without waiting for the overlay push. A provider whose gate fails is a provider hard-fail as specified by `overlay-apply-waves`.

#### Scenario: bun-bin gate fails

- **WHEN** `dev-lang/bun-bin`'s gate fails and `ralph-tui` is withheld on it
- **THEN** `ralph-tui` hard-fails naming `dev-lang/bun-bin`

#### Scenario: Consumer admitted after commit

- **WHEN** `dev-lang/bun-bin` passes its gate and commits
- **THEN** withheld consumers may be admitted before bun-bin's overlay push completes

### Requirement: One gate covers every distfile a unit publishes

When a unit publishes more than one assets distfile, all of them SHALL be staged for the same gate. This includes a Codex unit that publishes crates and a rusty_v8 snapshot. None of them SHALL be published before that gate passes.

#### Scenario: Codex with a rusty_v8 harvest

- **WHEN** a Codex full-path unit builds `codex-0.164.0-crates.tar.xz` and `rusty-v8-150.5.0-with-submodules.tar.xz`
- **THEN** both are staged for its gate
- **AND** neither publish cycle starts until the gate passes
