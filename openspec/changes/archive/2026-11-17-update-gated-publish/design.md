# Design

## Context

See `proposal.md` for motivation, and the specs under `specs/` for required behaviour. The current state that shapes the approach:

- **Full-path pipeline.** In `Update.Apply.Materialize` the order is: build the tarball, then `publishAssetCycle` (sidecars, assets commit, push, release), then `overlayAfterAssets` (ebuild write, `ebuild … manifest`, `egencache`), then the overlay commit. `ebuild … manifest` hashes whatever is in the manager `DISTDIR`, but the built tarball is not there: it is in the unit's temp `out/` directory, and the old order worked only because Portage downloaded the just-published asset. The new order therefore first copies the unit's built distfiles (including a harvested rusty_v8 archive) into the manager `DISTDIR` by basename, replacing any older file of that name, and only then runs `ebuild … manifest`. A first live run without that copy failed with `Couldn't download '<name>-vendor.tar.xz'`. The reuse path still lets Portage fetch the published release.
- **GitMv.** `Update.Apply.GitMv` commits straight after `egencache`. bun-bin's commit is delayed until ensure finishes.
- **Overlay publishing.** `update` never pushes the overlay today; it only makes signed local commits. Assets pushes go through `Update.Git` with SSH from `Update.SshAgent` and the Statuspage check from `Update.GitHubHealth`.
- **Smoke as a batch.** `Smoke.Run.runSmoke` does everything in one pass: sweep, image ensure, tree snapshot, sandbox probe, cache preparation, then sequential runs over a precomputed `[PlannedItem]`. `Smoke.Container` mounts the overlay worktree read-only and writes `/etc/portage` through a root setup script. `Smoke.CompileCache` already installs `/etc/portage/bashrc` phase hooks, and those hooks already use `addwrite` and a marker directory to pass data out of the Portage sandbox.
- **Locks.** Overlay `egencache`, `git add` and `git commit` share one critical section. Assets commit, push and release share another.
- **Overlay layout.** The overlay is a flat git worktree. md5-cache entries live under `metadata/md5-cache/<category>/<pf>`.

## Goals / Non-Goals

**Goals:**
- One smoke engine. Standalone `smoke` and the `update` gate run the same container code, checks and metrics, and differ only in overlay source, fetch behaviour and scheduling.
- Every gate, held-unit and push decision is a pure function over gathered state, so it can be unit-tested with fake runners and without Docker or a network.
- Nothing irreversible happens before the gate. That includes sidecars, commits, pushes and releases.

**Non-Goals:**
- Making `smoke` itself incremental or concurrent.
- Any change to how materialize containers build distfiles.
- Generalising the sync preflight to remotes other than each branch's upstream.

## Decisions

### Split `Smoke.Run` into a session and a run executor

A **smoke session** owns the command-scoped resources: sweep, image ensure, tree snapshot, sandbox probe, and compile-cache preparation and cleanup. It is opened with a bracket that removes the snapshot on exit. A **run executor** takes a session plus one planned run, and returns a result and a log path.

- `runSmoke` becomes: open a session, then fold the executor over the plan. Its behaviour does not change.
- `update` opens the session lazily, as an `async` started once the plan shows work. Its readiness is awaited before the first gate, and a failure there is surfaced as the "unready prerequisites" outcome.
- *Alternative:* call `runSmoke` per unit. Rejected: every gate would repeat the snapshot, probe and cleanup, and two `update` gates would race on cleanup.

### Plan gate runs with the existing lane planner, filtered to one PV

`Smoke.Plan` already derives lanes served from on-disk ebuilds and collapses equal ceilings. The gate calls it with the unit's snapshot overlay and keeps only the items for the unit's PV. This makes the PV-serves-no-lane, architecture-skip (now a failure) and Python-slot behaviour identical to `smoke`.

### Overlay snapshot per unit

For each gate, a temp directory under the unit's run tree is filled from:

1. the overlay at `HEAD`, written by `git read-tree HEAD` and `git checkout-index --all --prefix=<dir>/` through a private `GIT_INDEX_FILE`, so the overlay's own index is untouched and the host needs no `tar`;
2. the unit's package directory, copied over;
3. the unit's md5-cache entries `metadata/md5-cache/<category>/<pn>-<pvr>`, copied over, after removing that package's entries from step 1. An entry belongs to the package only when its name parses as `<pn>-<version>`, so `codex-acp-2.7.0` is not a `codex` entry.

The directory is bind-mounted read-only at `/var/db/repos/mndz`.

- Writing a ~MB tree per gate is cheap next to an emerge.
- *Alternative:* `git worktree add` plus copy. Rejected: it leaves worktree metadata in the repo and needs cleanup if the process crashes.
- *Alternative:* mount the live worktree. Rejected: it is nondeterministic under parallel units.

### Fetch shim via `FETCHCOMMAND` / `RESUMECOMMAND`

For gated runs that have staged files, the root setup script writes `/usr/local/libexec/mndz-fetch`, a POSIX `sh` script, and appends `FETCHCOMMAND` and `RESUMECOMMAND` lines to `make.conf` that call it with `"\${URI}" "\${DISTDIR}" "\${FILE}"`.

- When `URI` starts with `https://github.com/<owner>/<assets-repo>/releases/download/`:
  - the shim copies `/var/cache/mndz-staged/<basename>` to `${DISTDIR}/${FILE}` when it exists;
  - otherwise it prints `mndz: unstaged assets URL <URI>` and exits 1.
- Any other URL is handed to Portage's stock command. The setup script captures it with `portageq envvar FETCHCOMMAND` and `RESUMECOMMAND` into files under `/usr/local/libexec/mndz-fetch.d/`, before it appends the override. The shim `eval`s the captured command with `URI`, `DISTDIR` and `FILE` set.
- The staging directory is a per-unit temp directory holding hard links, or copies when crossing a device, of exactly the unit's built distfiles. It is bind-mounted read-only, so the manager `DISTDIR` itself is never mounted.
- Portage still runs its own size and hash verification after the fetch command returns.
- *Alternatives:*
  - TLS interception of `github.com`: needs a pass-through reverse proxy for every upstream GitHub archive, plus CA injection.
  - Portage `mirrors` `local` entries: these do not exercise the exact `SRC_URI` string.
  - Both were rejected during exploration.

### Unit pipeline as an explicit state machine

Each unit moves through `Built → Manifested → Gated → Published → Verified → Committed → Pushed`. Each transition records what is now irreversible: assets published, commit created. Held-unit capture, halt handling and interrupt handling all branch on that state, not on ad-hoc flags. `held.json` serialises the same state. A future `resume` would start from exactly that record.

### Gate scheduler

There is one scheduler thread in the apply phase.

- **Smoke lane.** An `MVar`-guarded FIFO of ready gates, served one at a time. Waiting happens outside the `--jobs` semaphore: the unit releases its job slot before it enqueues.
- **Dependency edges.**
  - After a unit is Manifested, the program parses the rewritten ebuild's dependency atoms. They are read from the regenerated md5-cache entry, which already flattens all five dependency classes.
  - Those atoms are intersected with selected packages that are not yet terminal. The unit waits on a per-package terminal `TMVar`.
  - The wait-for graph lives in one `TVar`. Adding an edge that closes a cycle fails every unit on that cycle immediately. This makes cycle detection deterministic, unlike timeouts.
- **Halt flag.** A `TVar Bool` set on overlay push failure. Every transition into `Published` or `Committed` checks it inside the same STM transaction that takes the publish slot.

### Held-unit capture and rollback

1. **Capture.**
   - `git add -N` the unit's new files, then `git diff --binary -M HEAD -- <unit paths>` produces the patch.
   - The intent-to-add entries are undone in the same step.
   - Distfiles are copied, not moved, so the manager `DISTDIR` stays consistent for its own accounting.
   - Logs are copied from the smoke log directory.
   - `held.json` is written last.
   - Everything is written to `<entry>.tmp` and renamed into place, so a partial entry never looks complete.
2. **Rollback**, only after the rename succeeds:
   - `git restore --source=HEAD --staged --worktree -- <tracked unit paths>`;
   - remove the unit's untracked paths.
3. "Unit paths" is the same set the commit would have staged: old and new ebuild, `Manifest`, and md5-cache entries. That set already exists for the commit, so rollback reuses it.

### Interrupts

`update` already installs teardown for the GPG and SSH agents. The held-unit sweep joins that teardown: on an async exception, each unit in a pre-`Committed` state with mutated paths is captured and rolled back, using the reason `interrupted`. The active smoke container is removed by the session bracket. A second interrupt during the sweep aborts the sweep and reports the units left dirty. The existing dirty preflight will name them on the next run.

### Sync preflight

`git fetch` of the upstream remote, then `git rev-list --left-right --count @{u}...HEAD`, with `HEAD` and `@{u}` resolved first. A detached `HEAD` or a missing `@{u}` fails before the fetch. This runs after the SSH agent is ready, so the fetch can use the key. It is wrapped in the Git Operations Statuspage check.

### Overlay push inside the overlay critical section

The push runs inside the overlay critical section, right after the commit. This keeps commit order and push order identical, and means a later commit can never be pushed ahead of an earlier one. Push latency extends the critical section. That is acceptable, because commits were already sequential.

### Real-URL verification

The verification parses the assets URLs from the unit's rewritten ebuild `SRC_URI`, which is the same string the gate's shim matched. It downloads each one with the existing HTTP client, following redirects, into the unit's temp tree, then compares size and every Manifest hash. Reuse-path units skip it, because their gate already fetched through the real URL.

### Disk metrics

- **Build directory.** A `post_src_install` bashrc hook, appended to the compile-cache hooks and present even with `--no-compile-cache`, runs `du -sk "${PORTAGE_BUILDDIR}"`. It writes `<category>/<pf> <kb>` to a file in a marker directory made writable with `addwrite`. This is the same pattern the configure-cache markers use.
- **Writable layer.** Read with `docker container inspect --size` before the container is removed.
- **Distfiles.** `du -sk` of the package step's `DISTDIR`, run by root in the container after that step.
- All values become attrs on the run span. The hook is installed only when metrics are recording.

## Verified behaviour

Recorded on 2026-11-17 on the operator's amd64 host (Docker 29.9.0), with the then-current `mndz-overlay-manager/smoke:local` image and a tree snapshot imported the same way `Smoke.Tree` does.

### Fetch shim (task 1.1)

Package `dev-util/cmake-language-server-0.1.11`, with its definition's accept keywords. Its `SRC_URI` names an upstream GitHub archive and `…/mndz-overlay-assets/releases/download/cmake-language-server-0.1.11/cmake-language-server-0.1.11-deps.tar.xz`. Portage's effective `FEATURES` included all six required sandbox features: `sandbox`, `usersandbox`, `userpriv`, `network-sandbox`, `ipc-sandbox` and `pid-sandbox`. `FETCHCOMMAND` and `RESUMECOMMAND` called the draft shim with `"\${URI}" "\${DISTDIR}" "\${FILE}"`. The staging directory was bind-mounted read-only at `/var/cache/mndz-staged`, and a write to it from the container failed with `Read-only file system`.

- **Staged file used and verified.** The package step passed. The deps tarball came from the staged copy, and the upstream archive was downloaded. With a staged file of the right name and size but random content, the fetch failed with `VERIFY FAILED! Reason: Failed on BLAKE2B verification`. Portage therefore verifies the shim's output against the Manifest.
- **Unstaged assets URL fails.** With an empty staging directory, the log shows `mndz: unstaged assets URL https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/…-deps.tar.xz`, then `Couldn't download '…-deps.tar.xz'. Aborting.`, and the package step exits 1.
- **Non-assets URLs download.** `https://github.com/regen100/cmake-language-server/archive/refs/tags/v0.1.11.tar.gz` was downloaded by the stock `wget` command line through the shim.
- Notes for the implementation:
  - Portage first tries its Gentoo mirrors (`http://distfiles.gentoo.org/distfiles/<xx>/<file>`) through the same `FETCHCOMMAND`. The shim passes those through as non-assets URLs, and they return 404.
  - `${FILE}` is Portage's temporary name (`<file>.__download__`). The shim therefore keys the staged file on the URI basename and writes to `${DISTDIR}/${FILE}`.
  - The stock commands captured from the image are `wget -t 3 -T 60 --passive-ftp -U "Portage (Gentoo, gentoo.org) distfile-fetch" -O "${DISTDIR}/${FILE}" "${URI}"`, plus `-c` for resume.

### Build-directory hook and writable layer (task 1.2)

A `post_src_install` hook in `/etc/portage/bashrc` ran `addwrite` on a marker directory created by root with `install -d -m 2775 -o root -g portage`. It then appended `${CATEGORY}/${PF} <du -sk ${PORTAGE_BUILDDIR}>` to a file there. `emerge --usepkg=n --getbinpkg=n dev-libs/oniguruma app-misc/jq` exited 0 with no `ACCESS VIOLATION`, and the file held one line per package: `dev-libs/oniguruma-6.9.10 8608` and `app-misc/jq-1.8.2 14444`. A package merged from a binary package does not run `src_install` and gets no line. `docker container inspect --size --format '{{.SizeRw}}'` on the running container printed `262967296`.

### Held capture round-trip (task 1.3)

The test ran in a scratch clone of the overlay. The ebuild `dev-util/hk/hk-2.12.0.ebuild` was renamed to `hk-2.13.0.ebuild`. The Manifest was edited, the md5-cache entry `hk-2.12.0` was renamed to `hk-2.13.0` and edited, and an untracked binary file was added to the package directory. The Manifest and md5-cache edits were made by hand, since git sees the same kinds of change either way. Another package was also dirtied.

- The capture used `git add -N` on the untracked unit paths, then `git diff --binary -M HEAD -- <unit paths>`, then `git reset -q` on those paths. It produced a patch with two renames (`similarity index 100%` and `97%`) and a `GIT binary patch`.
- Rollback ran `git restore --source=HEAD --staged --worktree` on the unit paths that exist at `HEAD`, then removed the unit's untracked paths. Afterwards `git status --porcelain -- <unit paths>` was empty, and the other package's change was still there.
- After `git apply`, `sha256sum` and the modes of every file under `dev-util/hk` and `metadata/md5-cache/dev-util` were byte-identical to before the rollback. A second capture of the re-applied tree gave the same patch byte for byte.
- `git restore` rejects pathspecs that do not exist at `HEAD`. Rollback must pass only `HEAD` paths to it. It must unstage and delete new paths separately, including new paths that were already `git add`ed before a later failure.

## Risks / Trade-offs

- **[Gate adds a smoke run per lane ceiling to every update; Rust packages take minutes to tens of minutes]** → The compile cache is on by default. Materialize overlaps the lane, and waits release job slots. The new metrics give data for later tuning.
- **[A host that cannot run smoke can no longer apply updates]** → This is deliberate. The errors name the exact prerequisite. `--no-smoke` is a future feature.
- **[The shim depends on `FETCHCOMMAND` semantics]** → Portage has documented and kept `FETCHCOMMAND`/`RESUMECOMMAND` for many years. A test asserts the rendered `make.conf` lines and runs the shim script against a fake `DISTDIR`.
- **[Dependency waits serialise gates more than strictly necessary, for example a whole package waits for every PV unit of its dependency]** → Accepted for simplicity. Dependency waits only affect gates, not builds.
- **[Snapshot from `HEAD` misses uncommitted, non-unit changes an operator expects to test]** → The dirty preflight already forbids dirt in selected packages and in emerged overlay atoms. Other dirt is irrelevant to the unit by construction.
- **[Overlay push inside the critical section stalls other commits during a slow push]** → Commits are sequential anyway. On push failure the halt stops further commits regardless.
- **[Held entries accumulate disk with large tarballs]** → They are kept on purpose. The README documents manual removal, and `resume` will consume them later.
- **[`git diff --binary` patch fails to apply if `HEAD` moves]** → The metadata records the base `HEAD`. The operator can `git apply --3way` or check out that base.
- **[Smoke and update running at the same time share the compile cache and volumes]** → Cleanup is already locked, with a 24-hour in-use protection. Snapshots are per command.

## Migration Plan

1. Before the first run after upgrading, the operator ensures that the overlay and assets branches track their upstream and are in sync, and that `ssh-identity` is configured. The first `update` that has work fails fast, with the fix named, if they are not.
2. The first `update` with work builds the smoke image if it doesn't exist, which needs the same space as `smoke`.
3. Rollback is reverting to the previous binary. No on-disk format is migrated: held entries are new, and the smoke image and volumes are unchanged.

## Future: `resume`

These are recorded here so the follow-up feature starts from the decisions already made:

- **Overlay push failure.** The unit's signed, gated commit is kept locally. All later publishing in the run halts, and the units in flight are held with reason `halted`. `resume` must be able to:
  - push an existing local gated commit;
  - re-gate and publish held entries, branching on whether `held.json` says their assets were already published.
- **Held entries.** These are the input format: patch, distfiles, logs, and `held.json` with its schema version, base `HEAD` and pipeline state. `resume` may also own deleting entries, for example `resume --drop`.
- **Deferred flags.** `--no-smoke` and `--no-push` were deferred together with `resume`, because their semantics, such as holding instead of committing, depend on it.
