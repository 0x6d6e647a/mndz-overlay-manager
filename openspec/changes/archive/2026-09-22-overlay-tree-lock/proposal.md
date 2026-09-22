## Why

`update --jobs` lets admitted packages rename, rewrite, and delete overlay ebuilds while another package reads those same ebuilds for atom closure, prune keep, or an ensure floor. The reader lists a directory and then opens a name that the other package has already renamed. That is an uncaught `openFile: does not exist`, and it aborts the process. The same walk sometimes swallows the error and treats the ebuild as absent, so a rename-away or prune can proceed without a consumer pin that was on disk. Coverage already failed `Apply Overlay Jobs Concurrent` on `grok-build-bin` this way. Default `--jobs` is the host processor count, so untargeted `update` of independent GitMv packages hits the same window.

## What Changes

- An apply-time observation of overlay ebuild names and bodies, and the ebuild rename, rewrite, or deletion that follows from it, are one critical section across admitted packages. A reader sees each other package's ebuild either under its current name with a complete body, or not at all.
- If that observation cannot be completed because an ebuild is missing or unreadable, the unit hard-fails, names the path, and does not mutate. The process does not die on an uncaught filesystem exception. Other selected packages continue.
- After an atom-closure wait, the package observes the tree again and publishes only from an observation that still shows its atoms satisfied.
- `ebuild … manifest` still overlaps other packages. Package `egencache` and the signed overlay commit stay in the existing git critical section. The atom-closure wait stays outside both sections.
- `outdated`, package check, and the plan phase keep reading ebuilds concurrently up to `--jobs`. They do not enter the apply ebuild critical section.
- Overlay ebuild `readFile` / `writeFile` / `renameFile` / `removeFile` go through one module. A quality-gate source test fails if apply code bypasses it or builds a private lock. Same-thread reentry of the critical section fails the test run instead of hanging.

## Non-goals

- Software transactional memory, `effectful`, `dejafu`, or `io-sim`.
- A filesystem lock that covers two `update` processes. Two processes can already race on the git index.
- Publishing ebuild bytes via a temp file and `rename`. The critical section writes the destination directly. Portage `manifest` and `egencache` run after the publishing package has finished writing that ebuild.
- Putting check, plan, Gentoo-repo scans, work-tree files, `Manifest`, or distfiles on the apply ebuild critical section.
- Changing `--jobs`, overlay wait-edges, commit-after-ensure, or the signed-commit message format.
- README or CLI flag changes. Operator recovery text for a missing ebuild is the spec delta; there is no new command.

## Capabilities

### New Capabilities

### Modified Capabilities

- `update-apply`: Concurrent apply must not abort the process when another package's ebuild disappears between listing and reading. The decision observation and that unit's ebuild publish are one critical section. A missing or unreadable ebuild in that observation hard-fails the unit without mutation. Manifest may still overlap. The atom-closure wait and the git/egencache critical section stay outside it. Check and plan stay off it.
- `overlay-atom-closure`: A closure or prune-keep scan must not drop an ebuild whose read failed and then continue. The rename-away, wait/refuse, and keep decisions use one coherent observation of the other packages' ebuilds, repeated after a wait before publish.

## Impact

- **Code:** new `Update.OverlayTree` (exposed for the regression test); `ApplyEnv` gains the apply ebuild lock next to the git lock; `AtomClosure`, `GitMv`, `OverlayWrite`, prune, and apply-time bun-bin/qlot/node-gyp meta reads take that lock around the observation and the publish. Check, plan, and `gencache` keep a separate lock so they can still read in parallel.
- **Tests:** the existing concurrent GitMv apply test; a two-thread test that a reader sees a complete old body or a complete new body; a source test that apply code cannot bypass the module. `hk check` remains the gate.
- **Specs:** `update-apply`, `overlay-atom-closure`. No new dependency and no operator flag.
