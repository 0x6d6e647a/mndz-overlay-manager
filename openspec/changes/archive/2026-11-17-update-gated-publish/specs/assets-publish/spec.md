# Spec Delta

## MODIFIED Requirements

### Requirement: Signed assets commit and push

After the unit's smoke gate has passed, as specified by `update-smoke-gate`, and after writing sidecars for a package version, the program SHALL create a GPG-signed git commit in the assets worktree that stages only those new/changed sidecar paths (including sidecars for every distfile published for that PV), with commit message `category/package: version` (version without leading `v`), then `git push` to the worktree’s configured remote. The program SHALL NOT write sidecars, commit, or push for a unit whose gate has not passed, or after publishing has halted as specified by `overlay-push`. Push failure SHALL be a hard failure for that package’s update attempt. The program SHALL NOT leave a successful package apply that depends on unpublished assets.

#### Scenario: Commit message matches overlay style

- **WHEN** assets commit is created for `dev-util/beads` at `1.0.5`
- **THEN** the commit message is exactly `dev-util/beads: 1.0.5`

#### Scenario: Push required

- **WHEN** the signed assets commit succeeds but `git push` fails
- **THEN** the package update hard-fails and overlay mutation for that package does not proceed

#### Scenario: Multi-distfile sidecars in one commit

- **WHEN** publishing two required distfiles for the same PV (for example a deps tarball plus a companion the package still requires)
- **THEN** one assets commit stages sidecars for both basenames under that package directory with message `category/package: version`

#### Scenario: Opencode deps-only sidecars in one commit

- **WHEN** publishing `opencode-2.0.3-deps.tar.xz` for `dev-util/opencode`
- **THEN** one assets commit stages sidecars for that basename under `dev-util/opencode/` with message `dev-util/opencode: 2.0.3`
- **AND** the commit is not required to stage a models.json sidecar

#### Scenario: No sidecars before the gate

- **WHEN** a full-path unit's gate fails
- **THEN** no sidecar for its distfiles exists in the assets worktree

## ADDED Requirements

### Requirement: Published assets are verified at their download URL

After a unit's release upload and before its overlay commit, the program SHALL download each published asset from the exact assets URL written in the unit's ebuild and compare its size and hashes with the unit's Manifest. A missing asset or a mismatch SHALL hard-fail the unit, and the unit SHALL be held as specified by `held-units`.

#### Scenario: Asset matches

- **WHEN** `https://github.com/<owner>/<assets-repo>/releases/download/hk-2.13.0/hk-2.13.0-crates.tar.xz` downloads with the size and hashes in `dev-util/hk/Manifest`
- **THEN** the unit proceeds to its overlay commit

#### Scenario: Asset not downloadable

- **WHEN** that URL returns HTTP 404 after the release upload succeeded
- **THEN** the unit hard-fails naming the URL, no overlay commit is created, and the unit is held with reason `verify`

#### Scenario: Reuse path is not re-verified here

- **WHEN** a unit took the reuse path
- **THEN** this verification is not run, because its gate already fetched the published asset

### Requirement: Assets worktree must be in sync with upstream before a publishing run

When at least one unit that needs work will attempt `DepsAndAssets` apply, `update` SHALL fetch the assets worktree's upstream before any overlay mutation or materialize `docker build`. It SHALL exit with status `1` when the assets worktree's current branch is detached, has no upstream, or is ahead of, behind, or diverged from its upstream. The error SHALL name the state.

#### Scenario: Leftover unpushed assets commit

- **WHEN** an earlier run crashed after an assets commit and before its push, and a DepsAndAssets package needs work
- **THEN** `update` exits with status `1` before mutating any package, naming the assets branch as ahead of its upstream

#### Scenario: No assets publish this run

- **WHEN** only `GitMvAndManifest` packages need work
- **THEN** `update` does not fetch the assets repository
