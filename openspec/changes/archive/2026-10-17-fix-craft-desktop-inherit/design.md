# Design

## Context

See `proposal.md` for why the ebuilds and the two specs change. Pull request #3 on `0x6d6e647a/mndz-overlay` is open, mergeable, and based on `e0f61ddf45fddc11a76815b657cb38181bd7e2c8`. Its head is `d38695463fe712bf37c608484609542831b90875` on `peterkmg/mndz-overlay` branch `fix-craft-desktop-inherit`. The contributor allowed maintainer edits. The thirteen commits are unsigned. Each subject is `category/pn: fix desktop inherit and zenity dep`, and each body ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

The local overlay checkout is `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay`. Portage reads that checkout. It is clean and already at the pull-request base. `commit.gpgsign` is true there, and commits are signed with `AB3AA8D9F11259B4` as Anthony Mendez. Recent subjects are one line with an empty body. A revision bump is `category/pn: <PVR>`.

Each pulled commit renames one ebuild to the next revision and changes two lines: `inherit cargo xdg` becomes `inherit cargo desktop xdg`, and `gnome-base/zenity` becomes `gnome-extra/zenity`. `media-gfx/vectorcraft` goes from `0.10.0-r1` to `0.10.0-r2`. The other twelve gain `-r1`. `Manifest` is untouched. The committed `metadata/md5-cache` rows use a `rust.eclass` digest that does not match this machine. `desktop.eclass` on this machine does match the digest in those rows.

`pycargoebuild --inplace` rewrites `CRATES`, `GIT_CRATES`, and the generated crate-license block. It does not rewrite `inherit` or `RDEPEND`. The next manager bump copies the donor ebuild.

## Goals / Non-Goals

**Goals:**

- `master` contains the thirteen revision ebuilds from the pull request, each in its own signed commit.
- Each subject is `category/pn: <PVR>` and each body is empty.
- Petr Komogortsev `<44289657+peterkmg@users.noreply.github.com>` stays the author. The committer is the signer.
- Each commit's `metadata/md5-cache` row is regenerated against this machine's `::gentoo`. Its `rust` digest matches an untouched cache on the base commit, its `desktop` digest matches `desktop.eclass`, and `_md5_` matches the ebuild.
- `pkgcheck` reports neither `MissingInherits` nor `NonexistentDeps` for these thirteen packages.
- The pull request is updated so GitHub can mark it merged, and the two spec deltas name `gnome-extra/zenity` and `desktop`.

**Non-Goals:**

- Editing the live Portage checkout until the replayed branch is ready to fast-forward.
- Injecting `inherit desktop` from Haskell.
- Republishing crates tarballs or editing `Manifest`.
- Running `emerge`.

## Decisions

### 1. Replay the pull-request commits in a worktree, then fast-forward the Portage checkout

Fetch head `d38695463fe712bf37c608484609542831b90875` and add a worktree. Leave `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay` on `master` until `pkgcheck` has a branch to fast-forward. If the fetched head is any other object, stop. The pull request moved.

Replay with `git cherry-pick` in the pull request's order, starting at the base. Do not `rebase --exec` and amend. An amend inside `--exec` does not become the parent of the next commit.

- **Alternative — check out the pull request in the Portage checkout:** rejected. Portage would see a half-rewritten tree.
- **Alternative — click Merge on GitHub, then reword `master`:** rejected. That publishes his hashes first, and the reword is a force-push of `master`.

### 2. One subject line, his author, this machine's signature

After each cherry-pick, derive the subject from the single new ebuild path. `app-office/deckcraft/deckcraft-0.7.0-r1.ebuild` becomes `app-office/deckcraft: 0.7.0-r1`. `media-gfx/vectorcraft/vectorcraft-0.10.0-r2.ebuild` becomes `media-gfx/vectorcraft: 0.10.0-r2`. The message file is that one line. Amend with `-F` and without `--reset-author`. `commit.gpgsign` signs the commit. If signing fails, stop. Do not pass `--no-gpg-sign`.

The expected subjects are:

- `app-office/deckcraft: 0.7.0-r1`
- `app-office/designcraft: 0.8.0-r1`
- `app-office/gridcraft: 0.7.0-r1`
- `app-office/wordcraft: 0.7.0-r1`
- `app-text/pdfcraft: 0.8.0-r1`
- `media-gfx/cadcraft: 0.7.0-r1`
- `media-gfx/figcraft: 0.6.0-r1`
- `media-gfx/lightcraft: 0.8.0-r1`
- `media-gfx/photocraft: 0.5.0-r1`
- `media-gfx/vectorcraft: 0.10.0-r2`
- `media-sound/soundcraft: 0.7.0-r1`
- `media-video/effectcraft: 0.10.0-r1`
- `media-video/filmcraft: 0.8.0-r1`

- **Alternative — keep `fix desktop inherit and zenity dep`:** rejected. Revision bumps in this overlay are named by `PVR`. The pull request keeps the explanation.
- **Alternative — keep the Claude trailer:** rejected. The trailer needs a body, and this overlay's commits have empty bodies. His author line is the credit.

### 3. Regenerate md5-cache inside each replayed commit

Before the replay, read the `rust` field from an `metadata/md5-cache` file on the base commit that this pull request does not replace. After each cherry-pick, run package-scoped `egencache` with the worktree as the `mndz` location. Use the argv from `Update.Md5Cache`: `egencache --repo mndz --repositories-configuration <fragment> --update <category/pn>`. The fragment is `[gentoo]` with `location` set to the discovered Gentoo tree (this machine: `/var/db/repos/gentoo`), then `[mndz]` with `location` set to the worktree, `masters = gentoo`, and `auto-sync = false`.

Amend the regenerated cache into that same commit. Do not run the manager `gencache` command. That command writes a separate `metadata: regenerate md5-cache` commit.

Check the amended commit before the next cherry-pick:

- Author name and email are Petr's.
- `%b` is empty and the subject is the line from Decision 2.
- `%G?` is `G`.
- The cache's `rust` digest equals the base digest, and its `desktop` digest equals `md5sum` of this machine's `desktop.eclass`.
- `_md5_` equals `md5sum` of the ebuild.
- `Manifest` is not in the commit.

- **Alternative — land his cache and add a fourteenth cache commit:** rejected. A package commit in this overlay carries the cache that matches its ebuild.
- **Alternative — keep his `rust` digest:** rejected. It does not match this tree, so Portage ignores the row.

### 4. Prove the two pkgcheck findings, then publish his branch and fast-forward master

Fast-forward the Portage checkout to the replayed tip. Run `pkgcheck scan -k MissingInherits -k NonexistentDeps` on the thirteen atoms. The scan must be clean. If it is not, move that checkout back to `origin/master` and do not push.

Then push the replayed tip to `peterkmg/mndz-overlay` `fix-craft-desktop-inherit` with `--force-with-lease`, expecting the previous head `d38695463fe712bf37c608484609542831b90875`. Fast-forward `origin/master` to the same tip. His head is then an ancestor of `master`, which is what GitHub uses to mark the pull request merged. Comment on the pull request that the subjects are now `category/pn: <PVR>`, the bodies were dropped, he is still the author, and the cache was regenerated on this machine.

If the push to his fork is rejected, do not force-push `master`. Push the fast-forward of `origin/master` and close the pull request with the same comment.

- **Alternative — GitHub "Rebase and merge" or "Squash and merge":** rejected. Those buttons create new commits on GitHub's servers. Squash also folds thirteen packages into one commit.

### 5. Spec deltas only; living specs move at archive

`storytold-craft-apps` and `media-gfx-photocraft-seed` each replace `gnome-base/zenity` in `GUI runtime dependencies` and gain a `Desktop install helpers` requirement. Do not edit `openspec/specs/` during the overlay work. Archiving this change syncs those deltas. `cargo-crates-assets` already requires the Cargo rewrite to keep conditional dependencies and desktop integration.

- **Alternative — teach apply to insert `desktop` into `inherit`:** rejected. The donor ebuild is the source of that line.

## Risks / Trade-offs

- **[Risk]** GPG signing prompts for each of the thirteen commits. → **Mitigation:** stop on a failed signature. Do not skip signing. The operator unlocks the key.
- **[Risk]** The contributor pushes more commits while the replay is in progress. → **Mitigation:** `--force-with-lease` against `d38695463fe712bf37c608484609542831b90875`. A mismatch stops the publish.
- **[Risk]** `pkgcheck` is clean and install still skips icons for a package he did not rebuild. → **Mitigation:** inheriting `desktop` makes `domenu` and `doicon` real commands, and those helpers fail the install when the file is missing. An emerge of all thirteen packages is out of scope.
- **[Risk]** A later bump copies an ebuild that dropped `desktop`. → **Mitigation:** the new requirement says the ebuild inherits `desktop`. The inplace Cargo update does not strip `inherit`.

## Migration Plan

1. Fetch the pinned head into a worktree. Abort if it is not `d38695463fe712bf37c608484609542831b90875`.
2. Record the base `rust` digest. Cherry-pick each commit, regenerate that package's cache, and amend the one-line subject. Check author, body, signature, and cache before the next pick.
3. Fast-forward the Portage checkout. `pkgcheck` the thirteen packages. On failure, point the checkout back at `origin/master` and stop.
4. Force-with-lease his branch, fast-forward `origin/master`, and comment. If his branch rejects the push, fast-forward `origin/master` and close the pull request with the same comment.
5. Archive this change so the living specs pick up the deltas.

Rollback before the push is deleting the worktree. Rollback after the push is reverting the thirteen commits on `master`. The installed packages stay on the unrevisioned ebuilds until the operator emerges the new revisions.
