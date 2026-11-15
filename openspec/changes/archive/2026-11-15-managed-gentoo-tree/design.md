# Design

## Context

See proposal.md (Why) for motivation. Facts below were checked at `main` `6469aa1` and in explore-session spikes on 2026-11-13 and 2026-11-14.

- Tree readers today: `gentooRepoPath` (`Update.Runtime.Ceilings`, a `portageq get_repo_path / gentoo` call) feeds the Go, Node.js, Rust, and SBCL ceilings and `discoverPythonSlotInventory`. `ecGentooRoot` (`app/Main.hs`) feeds ensure's `loadGentooToolchainMetas`. `discoverGentooLocationWith` (`Update.Md5Cache`) runs the same `portageq` call with a `/var/db/repos/gentoo` fallback. Every reader takes only a path and then reads files directly, so swapping in a path resolver is local to each call site.
- Host Portage tools: `mkEbuildRunner` (`Update.Apply.Env`) runs host `ebuild … manifest` with `DISTDIR` and `GENTOO_MIRRORS` overridden. `mkEgencacheRunner` builds its own `--repositories-configuration` (`[gentoo] location = …`).
- The recipe (`Update.Materialize.Recipe`) runs `emerge-webrsync` in the base step and in every toolchain `RUN`. That is about 11 snapshot syncs of about 35 s each per full build. Each layer's tree is frozen at that layer's first build. The baked tree is 161,587 of the image's 259,281 files.
- Container sessions already use `docker create … sleep infinity` plus `docker exec` (`Update.Process.Docker`), labeled by product, run id, and CLI pid.
- `check-cache` already has an exclusive `flock` on a sibling `.lock` file (`withExclusiveLock` in `Update.CheckCache`).

Spike results that shaped the decisions:

| Probe | Result |
|---|---|
| Host `git clone --depth 1 --branch stable` of gentoo-mirror | 12.8 s, 685 MB tree, about 96 MB `.git` |
| `git fetch --shallow-since=<T-6h>` then pick and `checkout --detach` | fetch 2.2–3.0 s, checkout 0.5 s |
| `GNUPGHOME=<tmp> git verify-commit --raw` on a mirror commit | `VALIDSIG … EF9538C9E8E64311A52CDEDFA13D0EF1914E7A72` (mirror key primary). A developer commit gives `NO_PUBKEY`. |
| Mirror key without Portage | WKD (`repomirrorci@gentoo.org`) and `keys.gentoo.org` by fingerprint both work. Refresh takes 0.4 s. The key expires 2028-07-01. |
| Binhost `Packages` header | An 8 KiB HTTP range request gives `TIMESTAMP`. It stayed at 2026-11-14 12:35 UTC for at least 18 h, so the index updates about once a day. |
| `ebuild manifest` and `egencache` in `materialize:local` as uid 1000, tree bound read-only at `/var/db/repos/gentoo` | Byte-identical Manifest (`hk`, and `wordcraft` with overlay `mndz-cargo.eclass`). md5-cache byte-identical to host `egencache` against the same tree. `egencache` needs a writable `--cache-dir`. |
| Named build context with `.dockerignore` listing `.git` | Honored. First transfer 228 MB in 7.4 s. Unchanged tree reused in 3.5 s. A one-file change re-runs the `RUN` that binds it. |
| Registry `HEAD /v2/gentoo/stage3/manifests/amd64-openrc` (anonymous token) | Digest in 0.4 s. Pull rate limit not decremented. Tag last moved 2026-11-09. |
| `emerge -p --getbinpkg` of the image toolchains against a tree 4 h and 8 h newer than the binhost index | Identical binary/source resolution. No drift observed in that window. |

## Goals / Non-Goals

**Goals:**

- One resolver that returns the managed tree path, used by every reader and by `smoke` later. One function that returns the tree identity (commit id).
- Make all tree I/O injectable (git, gpg, HTTP, registry), so tests never touch the network or the host tree.
- Keep the container-session model: one tools container per run, created lazily.

**Non-Goals:**

- Atomic tree swaps with two worktrees. The lock covers readers.
- Any tree source other than the git mirror.
- Changing how floors or atoms are chosen, beyond reading them from the managed tree.

## Decisions

### D1. Host `git` + `gpg` sync from the git mirror, not a container or snapshot

The sync runs on the host with `git` and `gpg`. Both are already prerequisites, and Haskell `http-client` covers the small HTTP reads (WKD key, binhost header, registry digest).

Alternatives considered:

- *`emaint sync` in a container.* It works, but it needs Docker for `outdated`. It also needs a `--tmpfs /var/lib/portage` because Portage writes root-owned state. `PORTAGE_REPOSITORIES` silently drops Portage's signature defaults. A root run left root-owned files in `.git`. And it creates a bootstrap loop: an image is needed to get a tree, and a tree is needed to build the image.
- *HTTP snapshot plus unpack (Haskell `emerge-webrsync`).* This needs `tar` and `xz` (host tools, or Haskell `tar` + `lzma` linking liblzma). Snapshots are daily only, there is no commit identity, and a snapshot-seeded tree has no `.git`, so the next git sync is a full clone anyway.
- *rsync.* Not needed. In `emerge-webrsync`, rsync only merges a snapshot into an existing tree.

### D2. Trust anchor: pinned mirror-key fingerprint, isolated keyring

`gentoo-tree` keeps a keyring in `…/overlay-manager/gentoo-keyring/` (mode 0700). A commit is accepted only on `VALIDSIG` whose last field (the primary fingerprint) equals the built-in `EF9538C9E8E64311A52CDEDFA13D0EF1914E7A72`. gpg's trust model (`TRUST_UNDEFINED`) is ignored on purpose, because the pin replaces it. The key is fetched by WKD first, then `keys.gentoo.org --recv-keys <fpr>`, and refreshed with `--refresh-keys <fpr>` on every sync.

If Gentoo rotates the key, sync hard-fails and the fix is a manager release.

Alternatives considered:

- *Ship `gentoo-release.asc` in the repository.* It goes stale and still needs refreshing.
- *Trust the whole Gentoo keyring.* That would accept developer keys for metadata commits.

### D3. Aligned target selection

The sync works as follows:

1. HTTP range request for `Packages`, giving `T`.
2. `git fetch --shallow-since=@(T-6h) origin stable`.
3. Target = newest commit on `FETCH_HEAD` whose committer is the mirror and whose subject matches `^YYYY-MM-DD HH:MM:SS UTC$`, with commit time ≤ `T − 1h`.
4. If there is none, deepen `--shallow-since` stepwise, up to `T − 7d`.
5. Verify the target, then `checkout --detach`.

The binhost URL comes from the host-architecture mapping the recipe already uses (amd64 → `…/releases/amd64/binpackages/23.0/x86-64`). The fallback rules are in the `gentoo-tree` spec.

The `.git` stays shallow. The program can run `git gc --prune` occasionally, but there is no requirement for it.

### D4. Locking: one lock file, shared for readers, exclusive for sync

`…/overlay-manager/gentoo.lock` uses `flock`. A work command that reads the tree takes `LOCK_SH` at its first read and holds it to exit. A due sync first tries to upgrade (release `SH`, take `EX`) before anything reads, then downgrades. Both wait (decision B, recorded in the explore session). In-place `checkout` under `EX` is safe, because no reader holds the lock.

The lock helper generalizes `withExclusiveLock` from `Update.CheckCache` to both modes, so there aren't two implementations. Containers bind the tree path while their run holds `SH`, so a sync from another run cannot change the tree under them.

Alternative considered: a worktree swap (`git worktree add` plus an atomic symlink rename). It takes 2.1 s, costs +590 MB, and readers never block. Rejected, because it adds disk use and garbage collection for a case the lock already covers.

### D5. Last-check stamp, not commit date, drives the max age

`gentoo-tree-max-age` (default 6h) is measured from a `last-sync-check` file written after every successful check, including a check where the commit didn't change. Under alignment the commit itself can be about a day old. Measuring by commit date would make every run sync.

### D6. Portage tools container

The tools container reuses `Update.Process.Docker`'s create/exec session code with a new mount profile:

- the tree read-only at `/var/db/repos/gentoo`
- the overlay and manager distfiles at their host absolute paths
- `--user <uid>:<gid>` and `HOME` on a writable scratch path
- `egencache --cache-dir` under that scratch path
- repository configuration in `PORTAGE_REPOSITORIES` (gentoo plus mndz)

Same absolute paths mean the existing `mkEbuildRunner` and `mkEgencacheRunner` request shapes (cwd, `DISTDIR`, `--repositories-configuration` locations) carry over. Only the command runner becomes an exec into the container.

Image choice: the sidecar's current image, or `MNDZ_MATERIALIZE_IMAGE` when set, or (none recorded) ensure with an empty floor set, which is the base-only image. It is created lazily on the first Portage tool call and removed at run end, with the same labels as sessions so stale-container cleanup also covers it.

Alternative considered: a separate tools image. It would give a faster `create` (fewer files) and more stability across toolchain changes. Rejected: BuildKit's layer cache already shares the base layer, and a second sidecar and prune policy aren't worth it.

### D7. Image builds bind the tree. No baked tree.

Ensure passes `--build-context gentoo=<tree>`. The tree root holds a `.dockerignore` listing `.git` and itself, and `.git/info/exclude` lists `.dockerignore`, so `git status` stays clean. Every Portage `RUN` adds `--mount=type=bind,from=gentoo,target=/var/db/repos/gentoo` (read-only by default). `emerge-webrsync` is deleted from the recipe. The base step becomes:

```
getuto; emerge --oneshot sys-apps/portage; emerge -uDN @world; emerge -n <tools>
```

`FROM gentoo/stage3:<tag>@sha256:<digest>`.

BuildKit puts the tree's content checksum into every Portage `RUN`'s cache key. After a tree change, the next build re-runs the whole chain from `base`, mostly installing binary packages from the cache mounts and the binhost. That's accepted: builds only happen when floors, the qlot or node-gyp version, the generator identity, or the stage3 digest change.

Alternative considered: pinning the commit in a cache mount (`--build-arg TREE_SHA`, `git fetch` inside the build). Reused builds take 4 s instead of 3.5 s plus checksumming, but it keeps a second tree copy (about 700 MB) and lets the build tree drift from the planning tree. A BuildKit git URL context didn't finish within 10 minutes.

### D8. Base freshness check

The check runs only inside ensure for the default tag. When `now − lastBaseCheck ≥ materialize-base-check-interval` (default 3d), the program sends `HEAD` to the registry manifest (anonymous bearer token from `auth.docker.io`, with OCI index and manifest-list `Accept` headers) and reads `Docker-Content-Digest`.

- A digest different from `image.json`'s `stage3Digest` forces a build.
- The same digest writes `lastBaseCheck`.
- A failure warns and doesn't write.

On the first build after this change there is no recorded digest, so the check runs and the recipe pins whatever it finds. The registry client is injectable.

### D9. Sidecar fields

`image.json` gains `treeCommit`, `stage3Digest`, and `lastBaseCheck`. Older sidecars without them parse as missing: an unknown digest makes the base check due, and an unknown tree commit is informational. The generator identity changes because the recipe changes, so the first ensure after upgrade rebuilds once, as expected.

### D10. Check cache

Deps-payload fingerprints gain `treeCommit`. Old entries lack it and miss once. The `check-cache` schema version stays at one, because a missing field is already a miss under the fingerprint rule.

### D11. Resolver surface

There is one module (working name `Update.GentooTree`) exposing:

- `resolveGentooTree :: TreeEnv -> IO (Either Text GentooTree)`: ensure the tree exists, sync if due or refreshed, take `SH`.
- `gentooTreePath :: GentooTree -> FilePath`
- `gentooTreeCommit :: GentooTree -> Text`

`TreeEnv` holds the injectable git, gpg, HTTP, clock, and lock operations. `PortageqRunner` and `gentooRepoPath` are deleted. Readers take a `FilePath` (or `GentooTree`), so tests inject a temp directory directly instead of faking `portageq`. The spine resolves the tree once per run, before planning.

## Risks / Trade-offs

- **The binhost can still lag the commit it aligned to.** `TIMESTAMP` is when the index was written, not proof that every package from that tree was built. → A one-hour margin, and the spikes saw no drift over 8 h. A source build is slow, not wrong.
- **About a day of tree lag for lane ceilings**, because the binhost index updates about daily. → Accepted. Ceilings have never needed the tip.
- **Docker now gates every `update` and `gencache`.** On a fresh host, the first one builds a base-only image (minutes). → Documented in the README. GitMv-only runs build no toolchains.
- **`docker create` of the image costs 15–18 s today** (it scales with file count). The tools container adds one create per run. → Removing the baked tree takes out 62% of the image's files. The daemon-side cause is tracked separately (`docker-create-slow-handoff.typ`).
- **A sync blocks behind long runs** (decision: wait). → Logged as "waiting for another run to release the Gentoo tree" so the wait is visible.
- **Every ensure build re-runs the whole layer chain after a tree change.** → Binary packages from the cache mounts and the binhost. Builds stay rare (D7).
- **GitHub outage on a fresh host** means no tree and a hard fail. → An existing tree carries through outages. Fresh hosts are rare.
- **Mirror key rotation** means sync hard-fails until a release. → Clear error naming the expected fingerprint. The key currently expires 2028-07-01.

## Migration Plan

1. On the first run after upgrade, the managed tree is cloned (about 13 s) and the keyring is fetched.
2. The first ensure rebuilds the image once (recipe and generator identity change; the base digest gets recorded). Old check-cache deps entries miss once.
3. Host Portage stays installed but unused. Nothing on the host needs cleaning.
4. Rollback means reinstalling the previous manager. It ignores `gentoo/`, `gentoo-keyring/`, and the new sidecar fields, and its own `emerge-webrsync` recipe rebuilds the image.

## Open Questions

- Whether the mirror's `stable` branch ever has metadata commits by a committer name other than "Repository mirror & CI". The target filter uses the subject pattern and the signature check as the real gates, so a name change only needs a matcher tweak.
- The exact `.dockerignore` handling if a future Docker release stops honoring it for named contexts. The spike shows it works on buildx 0.38.2.
