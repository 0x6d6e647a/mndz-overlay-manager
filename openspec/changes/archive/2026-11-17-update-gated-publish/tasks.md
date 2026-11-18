# Tasks

## 1. Verify unproven container and git behaviour

- [x] 1.1 In a container from the current smoke image, with all six Portage sandbox features on, set `FETCHCOMMAND`/`RESUMECOMMAND` to a draft shim, bind-mount a staging directory read-only, and emerge an overlay package whose `SRC_URI` names an assets URL. Done when `design.md` records that:
  - the staged file is used and verified against the Manifest;
  - an unstaged assets URL fails the fetch with the shim's message;
  - a non-assets URL still downloads.
- [x] 1.2 Add a draft `post_src_install` bashrc hook that runs `du -sk "${PORTAGE_BUILDDIR}"` and writes into an `addwrite` marker directory, then emerge one package with dependencies built from source. Done when `design.md` records that the hook writes one line per package without a sandbox violation, and that `docker container inspect --size` reports `SizeRw` for a running container on this host.
- [x] 1.3 In a scratch clone of the overlay, rename an ebuild, regenerate Manifest and md5-cache, capture with `git add -N` + `git diff --binary -M HEAD`, roll back with `git restore`, then `git apply` the patch. Done when `design.md` records that the tree after `git apply` is byte-identical to the tree before rollback, and that rollback leaves `git status --porcelain` empty for those paths.

## 2. Smoke session and run executor

- [x] 2.1 Split `Smoke.Run.runSmoke` into a bracketed session (sweep, image ensure, tree snapshot, probe, compile-cache preparation) and a per-run executor, keeping `runSmoke`'s behaviour. Verify that the existing `test/Test/SmokeRun.hs` tests pass unchanged and that a new fake-ops test opens one session and runs two items through the executor.
- [x] 2.2 Let `Smoke.Plan` plan a single package PV against a given overlay root, reusing lane derivation and ceiling collapse. Verify with `test/Test/SmokePlan.hs` cases for two ceilings, equal ceilings, a PV that serves no lane, and an architecture skip.

## 3. Overlay snapshot and fetch shim

- [x] 3.1 Add unit overlay snapshot composition: `HEAD` archive, the unit's package directory, and the package's md5-cache entries replaced. Verify with a test on a temporary git repo that another package's uncommitted rename is absent from the snapshot and the unit's rename is present.
- [x] 3.2 Let `Smoke.Container` take the overlay mount source as a parameter (worktree or snapshot). Verify with `test/Test/SmokeContainer.hs` that standalone create args still mount the worktree and gated args mount the snapshot read-only.
- [x] 3.3 Render the fetch shim script and the `make.conf` `FETCHCOMMAND`/`RESUMECOMMAND` lines for gated runs that have staged files, and add the read-only staging mount. Verify with:
  - rendering tests asserting standalone runs have no shim;
  - a test that runs the shim under `sh` against a fake `DISTDIR` for the staged, unstaged-assets and non-assets cases.
- [x] 3.4 Build a per-unit staging directory from the unit's built distfiles, hard-linking or copying them. Verify with a test that the directory contains exactly the unit's basenames and that the manager `DISTDIR` is not part of any mount.

## 4. Held units

- [x] 4.1 Add the held-units module:
  - entry path resolution;
  - patch capture with `git add -N` and `git diff --binary -M`;
  - distfile and log copies;
  - versioned `held.json`;
  - an atomic `.tmp` rename.

  Verify with temp-repo tests that the patch round-trips with `git apply`, that `held.json` has every field from the `held-units` spec, and that a failed write leaves no complete-looking entry.
- [x] 4.2 Add rollback of exactly the unit's paths, run only after a complete capture. Verify with tests that:
  - a renamed ebuild is restored and the new one removed;
  - another package's dirt is untouched;
  - a capture failure, injected through the fake runner, leaves the unit's changes in place with an error naming its paths.
- [x] 4.3 Make sure `eclean` never touches `held/`. Verify with an `eclean` test that the `held/` directory survives.

## 5. Sync preflight, SSH, and Statuspage

- [x] 5.1 Add the upstream sync check (detached, no upstream, ahead, behind, diverged) to `Update.Git`, run against the overlay when work exists and against the assets worktree when `DepsAndAssets` work exists, before mutation. Verify with `test/Test/Git.hs` fake-runner cases for each state, and an `update` preflight test showing no fetch when nothing needs work.
- [x] 5.2 Extend SSH readiness to overlay push and fetch: the overlay `origin` push URL goes through the same checks, and SSH is set up whenever work exists. Verify with `test/Test/Ssh.hs` cases that a GitMv-only run with work prepares SSH and that a run with nothing to do does not.
- [x] 5.3 Apply the Git Operations Statuspage rule before the sync fetch and before each overlay push, even with no `api.github.com` call. Verify with `test/Test/GitHubResilience.hs` cases from the `github-api-resilience` delta.

## 6. Overlay push and publishing halt

- [x] 6.1 Push the overlay's current branch after each signed overlay commit, inside the overlay critical section. Verify with fake-runner tests that commit and push alternate in order across two units, and that the success stdout line appears only after the push.
- [x] 6.2 Add the halt flag: on push failure, keep the commit, block further assets publishing, overlay commits and pushes, start no new units, and hold in-flight units after their gate. Verify with a fake-runner test of three units where the second push fails: the first unit is pushed, the second is committed but not pushed, and the third is held with reason `halted`. The run exits 1 and the error names the `git push` to run.

## 7. Pipeline reorder and verification

- [x] 7.1 Reorder the full path in `Update.Apply.Materialize`: build, overlay write, Manifest and egencache, gate, publish, verify, commit, push. Verify with fake-runner tests that no sidecar or assets commit happens before the gate, and that a gate failure publishes nothing and holds the unit.
- [x] 7.2 Add verification of the published assets URL against the Manifest, with failures held as `verify`. Verify with `HttpFake` tests for match, 404 and hash mismatch, and that reuse-path units skip it.
- [x] 7.3 Gate the reuse path and GitMv units before their commits. Verify with tests in `test/Test/Apply.hs` that a GitMv gate failure creates no commit and holds the unit, and that a reuse gate failure is held with assets recorded as published.
- [x] 7.4 Make the bun-bin commit-after-ensure rule also wait for its gate. Verify with `test/Test/OverlayWaves.hs` or `test/Test/Waves.hs` cases:
  - the gate passes while ensure fails: commit;
  - the gate fails: no commit, and the consumer hard-fails naming bun-bin;
  - GitMv-only: commit after the gate.
- [x] 7.5 Stage both distfiles for Codex units that harvest rusty_v8, and start neither publish cycle before the gate. Verify with a fake-runner test.
- [x] 7.6 Add the new hard-fail classes (gate, cycle, verify, push, halted) with actionable messages, and suppress the half-applied warning for held units. Verify with message tests, one per class.

## 8. Gate scheduling

- [x] 8.1 Add the smoke lane (FIFO, width one), with units releasing their job slot while they wait. Verify with a `--jobs 1` fake-clock test where unit B materializes while unit A is in its gated run, and two ready gates run in arrival order.
- [x] 8.2 Add dependency edges from the rewritten ebuild's md5-cache dependency atoms to selected, non-terminal packages, with the wait at the gate only. Verify with a test where `codex-acp` materializes concurrently with `codex` but gates after `codex` is terminal, and an unselected dependency adds no wait.
- [x] 8.3 After a dependency's failure, gate against `HEAD`, and detect cycles when an edge is added. Verify with tests that:
  - a failed dependency lets the dependent gate and commit;
  - a two-package cycle hard-fails both, naming both;
  - units outside the cycle continue.
- [x] 8.4 Wire smoke prerequisites and session readiness into `update`:
  - Docker version and containerd checks before mutation when work exists;
  - the session opened concurrently;
  - on failure, no new units start and in-flight units hard-fail.

  Verify with preflight tests and a fake-ops test where the probe fails after a GitMv rename, the unit is held, and no commit exists.

## 9. Interrupts

- [x] 9.1 Add the held-unit sweep to `update`'s teardown for asynchronous exceptions, holding units with reason `interrupted` before `Committed` and removing the active smoke container. Verify with a test that throws an async exception during a fake gated run and finds a held entry and a clean package directory.

## 10. CLI, help, and progress

- [x] 10.1 Add `update --no-compile-cache`, passed through to gated runs and cleanup. Verify with `test/Test/CLI.hs` parser tests and a fake-ops test that gated containers have no cache mount.
- [x] 10.2 Update `update --help` with the gate, the overlay push and the new flag. Verify with a help-text test matching the `cli-help` delta.
- [x] 10.3 Progress: the new full-path and reuse step order, the `smoke testing` step for GitMv, lane-wait and dependency-wait statuses, the lane label in the gate status, and the push shown in the commit bar. Verify with `test/Test/Progress.hs` step-sequence tests.

## 11. Metrics

- [x] 11.1 Add the disk metrics for all smoke runs: the build-directory hook (installed only when recording), the writable-layer size at teardown, and the package-step distfiles size. Verify with `test/Test/Metrics.hs` event tests using fake container output, and a `--no-metrics` test showing no hook.
- [x] 11.2 Nest gated-run spans under the unit's package span with package, PV, lane, stage and outcome, and add `slot.wait` kinds `smoke` and `gate-dependency`. Verify with event-tree tests over a fake `update` run.

## 12. Documentation

- [x] 12.1 Update the README `update` section with gated publishing, the pipeline order, the fetch shim, the prerequisites and `--no-compile-cache`. Verify by reading it against the `project-docs` delta and `update --help`.
- [x] 12.2 Document overlay push, the sync requirements and recovery, push-failure halting, and the `ssh-identity` requirement in the README. Verify against the `project-docs` delta.
- [x] 12.3 Document held entries in the README: when, where, contents, `git apply` re-use, and never pruned. Verify by following the documented `git apply` steps on an entry from task 4.1's test fixture.

## 13. Integration

- [x] 13.1 Run `openspec validate update-gated-publish --strict` and `just check`, and verify both pass.
- [x] 13.2 With the operator present, run a live `update` on one GitMv package and one full-path package. Verify that:
  - gates run before any publish;
  - both commits are pushed;
  - the assets release and its URL verification succeed;
  - run metrics include the gate spans and disk measurements.
- [x] 13.3 Force a live gate failure, for example with a temporary broken check in a scratch branch definition. Verify that nothing is published, a held entry exists, and the overlay matches `HEAD`.

## Workflow follow-up

- Merge the delta specs into `openspec/specs/` and scrub any change-delta wording when archiving.
- Archive the change after review.
