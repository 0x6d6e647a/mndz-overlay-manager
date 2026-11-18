# overlay-push Specification

## Purpose

Let `update` publish each gated overlay commit by pushing the overlay, while refusing to publish anything it did not itself gate in that run.

## Requirements

### Requirement: Each overlay commit is pushed

After each signed overlay commit, `update` SHALL `git push` the overlay's current branch to its configured upstream, before treating the unit as succeeded. The push SHALL publish only that branch, with no force. Overlay commits and pushes SHALL stay sequential.

#### Scenario: Unit success includes the push

- **WHEN** a unit for `dev-util/hk` commits `dev-util/hk: 2.13.0` and the push succeeds
- **THEN** the upstream branch contains that commit and stdout prints the unit's success line

#### Scenario: Two units push in commit order

- **WHEN** two units succeed during one run
- **THEN** each commit is pushed after it is created and before the next overlay commit is created

### Requirement: Overlay must be in sync with upstream before a publishing run

When at least one unit needs work, `update` SHALL fetch the overlay's upstream before any overlay mutation or materialize `docker build`. It SHALL exit with status `1` when the current branch is detached, has no upstream, or is ahead of, behind, or diverged from its upstream. The error SHALL name the state and the commits involved.

#### Scenario: Hand-made local commit

- **WHEN** the overlay branch has one local commit that is not on its upstream and a package needs work
- **THEN** `update` exits with status `1` before mutating any package
- **AND** the error names that commit and says the branch is ahead of its upstream

#### Scenario: Behind upstream

- **WHEN** the upstream has a commit the local branch lacks
- **THEN** `update` exits with status `1` naming the branch as behind

#### Scenario: No upstream configured

- **WHEN** the overlay's current branch has no upstream
- **THEN** `update` exits with status `1` naming the missing upstream

### Requirement: Sync checks run only when the run will publish

The overlay sync fetch SHALL run only when at least one unit needs work. The assets sync fetch SHALL run only when the assets worktree is required, as specified by `assets-publish`. Both SHALL run after SSH and token readiness for this run and before any mutation. When no unit needs work, `update` SHALL NOT fetch either repository.

#### Scenario: Nothing to do

- **WHEN** no selected package needs work
- **THEN** `update` does not fetch the overlay or the assets repository

### Requirement: Overlay push failure halts publishing

When an overlay push fails, the unit SHALL hard-fail and its commit SHALL be kept. After that, the command SHALL NOT create assets commits, pushes, or releases, overlay commits, or overlay pushes. Units not yet started SHALL NOT start. Units in progress SHALL continue up to their gate and SHALL then be held as specified by `held-units`.

#### Scenario: Network failure on push

- **WHEN** the push of `dev-util/hk: 2.13.0` fails
- **THEN** that commit remains in the local branch
- **AND** the error names the `git push` the operator can run
- **AND** no later unit in that run publishes or commits

#### Scenario: Unit in progress after a halt

- **WHEN** publishing halted while unit `dev-util/mise` was materializing
- **THEN** `mise` still runs its gate and is then held with its gate outcome recorded

#### Scenario: Halt exits one

- **WHEN** publishing halted during a run
- **THEN** the command exits with status `1`

### Requirement: Overlay push uses the assets push credentials

An overlay push SHALL use the same `ssh-identity`, session SSH agent, and push-URL checks as an assets push, as specified by `ssh-agent-session`. The overlay's push URL SHALL be read from its `origin` remote. A push URL that is not a GitHub SSH or web URL SHALL fail before any passphrase prompt.

#### Scenario: Same key

- **WHEN** the overlay's `origin` is `git@github.com:<owner>/mndz-overlay.git`
- **THEN** the overlay push offers only the key named by `ssh-identity`

### Requirement: Git Operations status is checked before each overlay push

Immediately before each overlay push and before the sync fetch, `update` SHALL apply the GitHub Statuspage Git Operations rule specified by `github-api-resilience`: hard-fail on `partial_outage` or `major_outage`, warn on `degraded_performance`, and warn and continue when Statuspage cannot be fetched.

#### Scenario: Git Operations outage before push

- **WHEN** Statuspage reports Git Operations as `major_outage` immediately before an overlay push
- **THEN** that push is not attempted and publishing halts as for a failed push
