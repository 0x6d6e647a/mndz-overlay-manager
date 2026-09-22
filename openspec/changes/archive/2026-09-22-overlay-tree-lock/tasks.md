# Tasks

## 1. Overlay ebuild IO module

- [x] 1.1 Add `Update.OverlayTree` with an unexported `InTree`, `newTreeLock`, and `withOverlayTree`. `readEbuild`, `writeEbuild` (`writeFile` of the destination), `renameEbuild`, `removeEbuild`, and `listEbuildNames` take `InTree` and do not acquire the lock. Same-thread reentry throws `ReentrantTreeLock` before `takeMVar`. Expose the module in `mndz-overlay-manager.cabal` because the test suite imports it. Verify with a two-thread test: a reader and a writer share one lock, the writer replaces an ebuild body under the lock, and the reader observes either the complete old body or the complete new body. Verify a nested `withOverlayTree` on the same thread throws `ReentrantTreeLock`.

## 2. Apply lock plumbing

- [x] 2.1 Add `aeTreeLock` to `ApplyEnv`, create it beside `aeOverlayLock` in `Update.Spine`, and create it in `mkTestApplyEnv`. Verify `cabal build all` succeeds and the existing `Apply Overlay Jobs Concurrent` test still compiles against the new field.

## 3. Route overlay ebuild IO through the lock

- [x] 3.1 Change atom-closure listing and body reads (`listNonLiveProviders`, `readPackageEbuildBodies`, and their callers) to take `InTree` from the caller. Remove the `try` that maps a read `IOException` to "no such ebuild". A listed path that cannot be read fails the unit with a message that names the path, without mutating. Verify the existing atom-closure rename-away and keep tests still pass, and add a test where a listed consumer ebuild is missing: the provider unit hard-fails, the message contains the path, and no rename or prune runs.
- [x] 3.2 Hold `aeTreeLock` across the GitMv observation and the `renameFile` or add-keep `writeFile`s in one `withOverlayTree` callback. If atom closure must wait, return without publishing, wait outside `aeTreeLock` and `aeOverlayLock`, then loop and publish only from a new satisfied observation. Manifest and `egencache` / commit stay on their current locks afterward. Verify `Git Mv Commits On Success`, the bun-bin add-keep tests, and `Apply Overlay Jobs Concurrent` pass, and that a wait-then-publish test still commits the provider before the consumer mutates.
- [x] 3.3 Hold `aeTreeLock` across DepsAndAssets overlay rewrite (template read is its own short `aeTreeLock` callback or part of the publish callback; the content write and template `removeFile` share the publish callback with the closure observation) and across prune's keep-set read plus `removeFile`. Verify an existing overlay-rewrite test and a reverse-dep prune test pass.
- [x] 3.4 Thread `InTree` through overlay bun-bin, qlot, and node-gyp meta reads, `ebuildFileMd5`, and fingerprint ebuild reads. Apply, including own-package md5 and fingerprint, uses `aeTreeLock`. The ensure closure that overlaps apply workers uses that same lock and only around the floor read, not around `docker build`. Check, plan, pre-apply floor scans, and `gencache` call `newTreeLock` per observation. Verify an ensure-overlap or floor-scan test and an md5-cache gate test pass.
- [x] 3.5 Map ebuild `IOException`s inside an apply or ensure observation to that unit's hard-fail or to ensure's pre-build failure. The message names the path. The lock is released and other packages continue. Verify a test that the failure is an `ApplyHardFail` (or ensure `Left`) and not an uncaught exception.

## 4. Keep the module the only ebuild IO

- [x] 4.1 Add a source test that fails if `src/Update/Apply/` or `src/Update/AtomClosure.hs` mentions `newTreeLock`, or if overlay ebuild `readFile` / `writeFile` / `renameFile` / `removeFile` appears outside `Update.OverlayTree`, aside from an explicit allowlist of non-ebuild paths (`Manifest`, check-cache document, work trees, distfiles, Docker recipes). Verify the test passes on this tree and fails when a raw ebuild `readFile` is temporarily introduced under `src/Update/Apply/` (revert that probe before finishing).

## 5. Gate

- [x] 5.1 Leave living `openspec/specs/` unchanged; the change deltas are the contract until archive. Run `openspec validate --change overlay-tree-lock --strict` and `hk check`. Verify both exit 0.
