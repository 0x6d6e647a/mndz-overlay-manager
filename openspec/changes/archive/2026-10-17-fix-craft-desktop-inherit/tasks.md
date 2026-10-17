# Tasks

## 1. Spec deltas

- [x] 1.1 Run `openspec validate --change fix-craft-desktop-inherit --strict` from the overlay-manager repo and confirm it exits 0. Confirm `git diff --stat` in that repo lists only files under `openspec/changes/fix-craft-desktop-inherit/`. No Haskell, `README.md`, `CONTRIBUTING.md`, or `AGENTS.md` change, so `just check` is out of scope for this change.

## 2. Replay the pull request

- [x] 2.1 In `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay`, confirm `git status` is clean and `HEAD` is `e0f61ddf45fddc11a76815b657cb38181bd7e2c8`. Fetch `pull/3/head` and confirm the fetched object is `d38695463fe712bf37c608484609542831b90875`. Stop if either check fails.
- [x] 2.2 Add a worktree for that head outside the Portage checkout. Confirm the Portage checkout is still on `master` at `e0f61ddf45fddc11a76815b657cb38181bd7e2c8`. From the base commit, record the `rust` digest in an `metadata/md5-cache` file this pull request does not replace.
- [x] 2.3 Cherry-pick the thirteen commits in order. After each pick, run package-scoped `egencache` with the worktree as the `mndz` location, using the `Update.Md5Cache` argv from design Decision 3, and amend that cache plus the one-line `category/pn: <PVR>` subject without `--reset-author`. Confirm each amended commit has author `Petr Komogortsev <44289657+peterkmg@users.noreply.github.com>`, an empty body, signature `%G?` of `G`, the subject from design Decision 2, a cache `rust` digest equal to the recorded base digest, a `desktop` digest equal to `md5sum` of this machine's `desktop.eclass`, `_md5_` equal to `md5sum` of the ebuild, and no `Manifest` path. Stop on a failed signature. Do not pass `--no-gpg-sign`.

## 3. Publish

- [x] 3.1 Fast-forward the Portage checkout to the replayed tip. Run `pkgcheck scan -k MissingInherits -k NonexistentDeps` on the thirteen packages. Confirm the scan is clean. If it is not, point the checkout back at `origin/master` and do not push.
- [x] 3.2 Push the replayed tip to `peterkmg/mndz-overlay` `fix-craft-desktop-inherit` with `--force-with-lease` expecting `d38695463fe712bf37c608484609542831b90875`, then fast-forward `origin/master` to that tip. Comment on pull request #3 that the subjects are `category/pn: <PVR>`, the bodies were dropped, Petr Komogortsev remains the author, and `metadata/md5-cache` was regenerated on this machine. Confirm the pull request state is `MERGED`. If his fork rejects the push, do not force-push `master`; fast-forward `origin/master` and close the pull request with that same comment, then confirm the state is `CLOSED`. Remove the worktree.

## Workflow follow-up

- Archive `fix-craft-desktop-inherit` after the overlay push. Archiving syncs the deltas into `openspec/specs/storytold-craft-apps/spec.md` and `openspec/specs/media-gfx-photocraft-seed/spec.md`.
- After that sync, run `openspec validate --specs --strict` and confirm it exits 0.
