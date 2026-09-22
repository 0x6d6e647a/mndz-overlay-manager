# Design

## Context

See proposal.md for why concurrent apply aborts or drops an ebuild. Spec deltas in `specs/update-apply/spec.md` and `specs/overlay-atom-closure/spec.md` are the behavior contract. This document is the mechanism.

Today `aeOverlayLock` covers only package `egencache` and overlay `git add` / `git commit` (`Update.Apply.Commit`). GitMv `renameFile`, bun-bin add-keep `writeFile`, DepsAndAssets `writeFile` / template `removeFile`, and prune `removeFile` run outside it. Atom closure lists a package directory and then `readFile`s the names (`readPackageEbuildBodies` is uncaught; `listNonLiveProviders` turns any `IOException` into "no such ebuild"). Ensure's node-gyp / bun-bin / qlot floor reads use the same list-then-read while other packages publish. Check and plan finish before that publish and already run under `--jobs`.

`MVar` is not reentrant. A snapshot that holds the lock and then calls a helper that takes it again deadlocks.

## Goals / Non-Goals

**Goals:**

- One apply-wide exclusion for a coherent ebuild observation plus the publish that follows from it.
- `InTree` so overlay ebuild IO cannot be called unless that exclusion is held.
- Check, plan, and `gencache` keep parallel reads on a lock that is not the apply lock.
- A missing or unreadable ebuild becomes that unit's hard-fail (or ensure's failure), and the lock is released.
- Same-thread reentry throws instead of hanging.
- A source test in the existing suite stops apply code from bypassing the module.

**Non-Goals:**

- See proposal.md Non-goals. In particular: no second library, no temp-file publish, no multi-process flock, no reader-writer lock.
- Do not hold the ebuild exclusion across manifest, `egencache`, git, GPG, Docker, network, vendor, or the atom-closure wait.
- Do not take `aeOverlayLock` while the ebuild exclusion is held.

## Decisions

### 1. A second `MVar`, `aeTreeLock`, beside `aeOverlayLock`

Create it in `Update.Spine` where `aeOverlayLock` is created, and in `mkTestApplyEnv`. Store it on `ApplyEnv`.

The git lock stays the long critical section (Portage `egencache` and git). The tree lock is only the directory snapshot and the ebuild syscalls. Manifest stays outside both, so it still overlaps another package's publish.

Alternatives:

- Reuse `aeOverlayLock`. A package inside `egencache` would block every other package's snapshot and ebuild publish for the whole Portage run.
- An flock file in the overlay. That covers two processes, which this change does not try to fix, and it does not fix the in-process race any better than an `MVar`.

### 2. `Update.OverlayTree` is the only overlay ebuild IO

Expose the module. The test suite imports it, which is the reason to put it in `exposed-modules` rather than `other-modules`.

```haskell
data InTree = InTree          -- constructor not exported
data TreeLock = TreeLock ...  -- constructor not exported

newTreeLock :: IO TreeLock
withOverlayTree :: TreeLock -> (InTree -> IO a) -> IO a

readEbuild   :: InTree -> FilePath -> IO Text
writeEbuild  :: InTree -> FilePath -> Text -> IO ()  -- writeFile of the destination
renameEbuild :: InTree -> FilePath -> FilePath -> IO ()
removeEbuild :: InTree -> FilePath -> IO ()
listEbuildNames :: InTree -> FilePath -> IO [FilePath]
```

`withOverlayTree` is the only function that takes the `MVar`. The others perform the syscall and do not acquire. `writeEbuild` writes the destination path directly while the caller holds `InTree`.

Callers that need a decision write one callback: observe, and either return "wait" / "fail" without publishing, or publish before the callback returns. List and read of one observation happen in that same callback. A helper that listed outside and read inside would recreate the race.

`discoverBunBinMetas`, qlot, and node-gyp meta reads, `ebuildFileMd5`, and `computeFingerprintFromDir`'s ebuild reads take `InTree` (or call these functions). Gentoo-repo scans, `Manifest`, Cargo work trees, and distfiles stay on their current IO.

Alternatives:

- Each helper acquires the lock itself. The snapshot then deadlocks on the first nested read.
- Leave a quiescent `readFile` exported for convenience. Apply can call it during a cross-package scan and skip the exclusion.

### 3. Who passes which lock

| Caller | Lock |
|---|---|
| Apply cross-package observation and the publish in that callback (atom closure, rename-away, prune keep, GitMv rename / add-keep writes, overlay rewrite write + template delete, ensure floor read while workers run) | `aeTreeLock` |
| Apply own-package reads sequenced on that package's worker (md5 gate, fingerprint, donor/template read) | `aeTreeLock`, as its own short callback. One worker owns the directory; taking the apply lock anyway means `src/Update/Apply/` never builds a private lock |
| Check, plan, pre-apply floor scans, `gencache` | `newTreeLock` per observation (or per package). Not `aeTreeLock`. No publisher is running, so distinct locks stay parallel |

`src/Update/Apply/` and `Update.AtomClosure` receive `InTree` or use `aeTreeLock` from `ApplyEnv`. They do not call `newTreeLock`. `Update.Spine`'s ensure closure that overlaps workers captures the same `aeTreeLock` and holds it only around the floor read, not around `docker build`.

Atom closure session setup (`bunBinWouldKeepPin` before the pool) uses `aeTreeLock`. No worker has started, so the hold is uncontended, and the read goes through the same API.

### 4. Wait, then observe again, then publish

`ensureAtomClosedForWrite` may wait. The callback must not wait while it holds `InTree`.

```text
loop:
  decision <- withOverlayTree aeTreeLock $ \t ->
    snapshot t
    case atoms of
      NeedWait p -> pure (Wait p)          -- no publish
      Refuse     -> pure Refuse
      Ok plan    -> publish t plan >> pure Done
  case decision of
    Wait p -> wait outside both locks; loop
    Refuse -> hard-fail unit, no mutation
    Done   -> manifest, then aeOverlayLock for egencache and commit
```

The successful publish and the snapshot that justified it are the same callback. After a wait the loop snapshots again. `wireAtomClosureSlots` still releases the job slot during the wait.

### 5. Read and write errors become a unit hard-fail

Inside the callback, a missing file or any other `IOException` from ebuild IO fails that unit (or fails ensure before `docker build`). The message names the path. `withOverlayTree` releases the `MVar` on the way out. Other packages continue. Do not omit the ebuild and proceed. Remove `listNonLiveProviders`'s `try` that maps every `IOException` to `Nothing`.

Same-thread reentry is different: before `takeMVar`, if this thread already owns the lock, throw `ReentrantTreeLock`. That is a programming error, not an operator hard-fail. Tests expect the exception. The owner check happens before `takeMVar`, so a nested call fails instead of blocking.

### 6. Source test

A test reads the Haskell sources and fails when:

- `src/Update/Apply/` or `src/Update/AtomClosure.hs` mentions `newTreeLock`
- overlay ebuild `readFile`, `writeFile`, `renameFile`, or `removeFile` appears outside `Update.OverlayTree`, except an allowlist of files that touch `Manifest`, the check-cache document, work trees, distfiles, Docker recipes, or similar non-ebuild paths

The allowlist is explicit in the test. A new raw ebuild read fails `hk check` even though GHC accepts it.

## Risks / Trade-offs

- [A forgotten ebuild read still compiles] → The source test and the unexported `InTree` constructor. The test is the backstop; the type only forces callers who already use the module.
- [`writeFile` can truncate a file that Portage or a bypassed reader opens] → Accepted. Manifest and `egencache` for that package run after the callback returns, and the package does not write that ebuild again until a later unit on the same worker. `writeEbuild` is the single function to switch to temp-file-plus-`rename` if a torn body shows up later. Call sites would not change.
- [Snapshot holds the lock across every other package's ebuild] → The mndz overlay is small and the reads are local. Manifest, Docker, and git stay outside. Do not widen the callback.
- [Own-package md5 and fingerprint take `aeTreeLock`] → They queue behind another package's snapshot for one package's files. That is the cost of banning a private lock under `Apply/`.
- [Check uses a fresh lock per observation and so does not exclude a publisher] → Check and plan complete before apply publish. The ensure path that overlaps workers is the one required to use `aeTreeLock`.
- [Reentrant detection races] → The owner `IORef` is only a same-thread check before `takeMVar`. Two different threads still serialize on the `MVar`.

## Migration Plan

No on-disk migration and no config change. Rollback is reverting the change. A run that hits a missing ebuild hard-fails that unit instead of aborting the process; other packages may already have committed, which matches existing per-unit commit behavior.

## Open Questions

None. The behavior contract is in the spec deltas, and the lock, witness, and error policy above are fixed for implementation.
