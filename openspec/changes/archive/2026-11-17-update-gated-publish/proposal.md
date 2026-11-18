# Proposal

## Why

`update` publishes assets (assets-repo commit, `git push`, GitHub release) and creates overlay commits for new ebuilds that nobody has installed. `smoke` can now install and check any overlay ebuild in a clean, sandboxed container, so a broken bump can be stopped before anything about it goes public. `update` also stops short of the last step: the operator pushes the overlay by hand, which is where untested ebuilds reach users.

## What Changes

- **Smoke gate.** Every `update` unit that needs work (GitMvAndManifest, and DepsAndAssets full and reuse path) is smoke-tested before anything about it is published or committed. The gate runs the new PV once per distinct lane ceiling it serves, with the same checks `smoke` runs. There is no opt-out flag.
- **Reordered publish pipeline** per unit: build → overlay edit, `ebuild … manifest`, `egencache` → **smoke gate** → assets sidecars, commit, push, release → **verify the real download URL against the Manifest** → signed overlay commit → **overlay `git push`**.
- **Unpublished distfiles reach the gate through a Portage fetch shim.** Portage still computes the exact `SRC_URI` an end user's Portage would. The shim serves staged files for assets-repository URLs from a read-only per-unit staging mount, fails on an assets-repository URL that is not staged, and leaves every other URL to the stock fetch. No TLS interception, DNS change, or proxy.
- **Deterministic overlay view.** A gated run sees the overlay at `HEAD` plus only its own unit's changes, never other units' half-finished work.
- **Scheduling.** Gated runs go through one smoke lane, one at a time. A unit waiting for the lane or for a dependency does not hold a `--jobs` slot. A unit whose rewritten ebuild depends on another overlay package being updated in the same run waits, at its gate only, for that package's outcome. It is then tested against whatever `HEAD` holds. Dependency cycles hard-fail the units involved.
- **Held units.** When a unit fails its gate, fails URL verification, is interrupted, or is stopped because publishing halted, its uncommitted work (overlay diff, staged distfiles, logs, metadata) is first saved under the manager cache. Only then is the overlay rolled back to `HEAD`. If saving fails, nothing is rolled back.
- **BREAKING: `update` pushes the overlay.** After each unit's signed overlay commit, `update` pushes the overlay's current branch to its upstream. Before any mutation in a run that will publish, `update` fetches the overlay and assets repositories and refuses to start if either is ahead of, behind, or diverged from its upstream. If an overlay push fails, the commit is kept and all further publishing in that run stops.
- **BREAKING:** runs that only bump GitMv packages now need SSH (`ssh-identity`) and the Git Operations Statuspage check, because they push the overlay.
- **BREAKING: `update` builds and uses the smoke image and its tree snapshot** whenever at least one unit needs work. It needs Docker 28 or newer, the containerd image store, and a passing sandbox probe.
- An ebuild not keyworded for the host architecture fails its gate.
- A gated run that runs out of disk space fails its gate. Gated runs are never retried.
- `update` gains `--no-compile-cache`, passed through to its gated runs.
- **Metrics (collection only).** Smoke runs, both standalone and gated, record:
  - the peak Portage build directory size of every package built;
  - the container's writable-layer size at teardown;
  - the size of the package step's fetched distfiles.

  In `update`, gated runs are recorded under the unit's span, and waits for the smoke lane or for a dependency are recorded as `slot.wait` spans.

## Non-goals

- `--no-smoke`, `--no-push`, and a `resume` command. Held entries are written in a form `resume` can later consume, but nothing reads them in this change.
- Using the new disk metrics in any estimate, gate, or report.
- Smoke on architectures other than the host's.
- Retrying gated runs, or estimating or reserving disk space for gated builds.
- Changing what standalone `smoke` selects or prints, or making it publish anything.
- Capture and rollback for failures before the gate (rename, `ebuild … manifest`, `egencache`). They keep the existing half-applied warning.
- Pushing anything other than the overlay's current branch and the assets worktree. No tags, other branches, or other remotes.
- Ordering units by overlay dependencies anywhere other than at the gate. Materialize still runs in parallel.

## Capabilities

### New Capabilities
- `update-smoke-gate`: how `update` smoke-tests each unit before publishing:
  - which runs make up a gate, and the overlay snapshot they see;
  - the fetch shim and staged distfiles;
  - the smoke lane and dependency ordering;
  - prerequisites and when they are set up;
  - outcomes (architecture skip, disk exhaustion, no retry), reporting, and the compile cache flag.
- `overlay-push`: `update` pushing the overlay. Covers the sync preflight for the overlay and assets repositories, the per-unit push, the stop on push failure, and push authentication.
- `held-units`: saving a unit's uncommitted work before rolling the overlay back. Covers when it happens, the on-disk layout and metadata, the rollback rules, and retention.

### Modified Capabilities
- `update-apply`:
  - the signed overlay commit follows the gate and verification;
  - the full-path order puts Manifest before publish;
  - the bun-bin commit-after-ensure rule also waits for its gate;
  - new hard-fail classes are identifiable;
  - the half-applied warning yields to held-unit capture.
- `assets-publish`:
  - the assets commit, push and release happen only after a passed gate;
  - each published asset is verified at its download URL;
  - the assets worktree must be in sync with its upstream.
- `update-command`: the subcommand-local `--no-compile-cache` flag.
- `smoke-image`: `update` builds and uses the smoke image.
- `smoke-environment`:
  - the tree snapshot, its cleanup and the sandbox probe also apply to `update`;
  - gated runs mount a unit snapshot and fetch through the shim.
- `smoke-compile-cache`: cleanup and `--no-compile-cache` also apply to `update`.
- `disk-space-preflight`: the smoke image build bound and the no-estimate rule also apply to `update`.
- `cli-concurrency`: the smoke lane is width one across `update`, and lane and dependency waits hold no job slot.
- `cli-activity`: the full-path step order changes, and new gate, verify and push steps appear.
- `run-metrics`: smoke disk measurements, gate span nesting, and new `slot.wait` kinds.
- `ssh-agent-session`: an overlay push also needs `ssh-identity`. A GitMv-only `update` that will publish now sets up SSH.
- `github-api-resilience`: the Git Operations check also runs before overlay pushes and the sync fetch.
- `cli-help`: `update --help` documents gating, pushing and `--no-compile-cache`.
- `project-docs`: the README documents gated publishing, overlay push, held entries, and the new prerequisites.

## Impact

- Code:
  - `src/Update/Apply/Materialize.hs` (pipeline reorder, gate, verification), `src/Update/Apply/Commit.hs`, `src/Update/Apply/GitMv.hs`;
  - `src/Update/Git.hs` (overlay push, fetch, ahead/behind);
  - `src/Update/Spine.hs` and the update preflight (sync checks, smoke prerequisites);
  - `src/Update/SshAgent.hs` and `src/Update/GitHubHealth.hs` (overlay push);
  - `src/Smoke/Container.hs` (overlay mount source, fetch shim, metric hooks), `src/Smoke/Run.hs`, `src/Smoke/Plan.hs` (planning a single PV);
  - `src/Smoke/Tree.hs` and `src/Smoke/Image.hs` (use from `update`);
  - `src/CLI/Parser.hs`, `src/CLI/Progress.hs`, `src/Metrics/*`;
  - a new held-units module.
- Tests:
  - pipeline order and gate outcomes, with fake runners;
  - shim rendering; snapshot composition; held capture and rollback;
  - sync preflight; dependency-edge and cycle scheduling;
  - parser; metrics events.
- Operator workflow:
  - the overlay must have an upstream and be in sync before `update`;
  - `update` now pushes;
  - `update` runs that do work take noticeably longer, by one smoke run per lane ceiling per unit.
- Disk: held entries under `<cache>/mndz/overlay-manager/held/`, never pruned by the program.
- Docs: README `update`, `smoke` and config sections; `update --help`.
