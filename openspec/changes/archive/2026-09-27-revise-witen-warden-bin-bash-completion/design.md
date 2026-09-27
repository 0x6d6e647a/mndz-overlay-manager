# Design

## Context

See proposal.md for why the completion file is gated. The live overlay file is `net-analyzer/witen-warden-bin/witen-warden-bin-0.1.19.ebuild`. It inherits `unpacker` and `systemd`, declares `IUSE="iptables"`, and always `doins` the deb's `usr/share/bash-completion/completions/warden`. The overlay Manifest is thin (`thin-manifests = true`), so it holds only the two `DIST` lines. The matching cache is `metadata/md5-cache/net-analyzer/witen-warden-bin-0.1.19`. `GitMvAndManifest` renames the newest ebuild to the bare remote PV and copies the body unchanged.

## Goals / Non-Goals

**Goals:**

- Publish `witen-warden-bin-0.1.19-r1.ebuild` in place of the unrevisioned ebuild, with `bash-completion` controlling that one file and its dependency.
- Keep the systemd unit, OpenRC script, logrotate snippet, distfiles, and `iptables` flag on the revision.
- Leave the manager's apply code alone. The next upstream PV copies this body forward and drops the revision.

**Non-Goals:**

- No edit to the completion script's contents. The deb file is installed as upstream wrote it.
- No Haskell change, and no edit to the living seed spec until this change is archived.
- No merge of a `USE=-bash-completion` image onto the host. That case is proved from the install image only.

## Decisions

1. **Revision bump, then delete the unrevisioned ebuild.** 0.1.19 is already merged, so an in-place edit of the same filename would not be a Portage upgrade. The new file is `witen-warden-bin-0.1.19-r1.ebuild`. The old ebuild is removed in the same overlay commit so only one 0.1.19 ebuild remains. PV stays `0.1.19`, so `warden --version` still prints `warden 0.1.19`.

2. **Gate with the global flag, not a forced default.** `IUSE="bash-completion iptables"`. No leading `+`. This host's `make.conf` already enables `bash-completion`, so the revision keeps the file here. `iptables` stays off in the ebuild and on here for the same reason it is on now.

3. **Install through `bash-completion-r1`.** The ebuild is EAPI 8. Inherit `bash-completion-r1` next to `unpacker` and `systemd`, and when the flag is on call `newbashcomp` on the unpacked deb file with the installed name `warden`. That lands on `/usr/share/bash-completion/completions/warden`. The other CLI ebuilds inherit `shell-completion` because they also install zsh and fish. This package does not, and `bash-completion-r1` is the EAPI 8 entry point that still provides `newbashcomp`.

4. **Depend on `app-shells/bash-completion` only when the flag is on.** The script calls `_init_completion`. `RDEPEND` gains `bash-completion? ( app-shells/bash-completion )`. The flag off omits both the file and the atom. `bash-completion` is a global USE flag, so `metadata.xml` does not gain a local flag description.

5. **Cache and Manifest stay package-local.** Run `ebuild … manifest` for the `-r1`. The two `DIST` lines stay. Regenerate the package cache with the same package-scoped `egencache --repo mndz --update net-analyzer/witen-warden-bin` shape the manager uses. Remove `metadata/md5-cache/net-analyzer/witen-warden-bin-0.1.19` if it is still present after that run. Do not use the manager `gencache` command. That command commits every cache path under a metadata subject. This revision is one signed overlay commit, subject `net-analyzer/witen-warden-bin: 0.1.19-r1`, containing the ebuild swap and the cache swap.

6. **Prove both flag values without changing the host's installed completion.** Emerge `=net-analyzer/witen-warden-bin-0.1.19-r1` with the host USE (flag on). The completion file stays, the version string stays `0.1.19`, and the service stays disabled. For the off case, run an `ebuild install` with `USE=-bash-completion` and inspect that image. Do not merge it.

## Risks / Trade-offs

- [Stale unrevisioned md5-cache] → The overlay commit deletes `metadata/md5-cache/net-analyzer/witen-warden-bin-0.1.19` when `egencache` leaves it behind. The `-r1` cache is the one that remains.
- [A later `GitMvAndManifest` drops `-r1`] → That is the existing rename rule. The copied body still has the flag. No manager special case.
- [The upstream completion file disappears from a future deb] → `newbashcomp` fails the build when the flag is on. The off build does not need the file.
- [The completion script is behind `warden --help`] → Accepted. Refreshing it is an upstream request, not this revision.
- [Portage image directory is not readable unprivileged] → The off-flag image check and the on-flag emerge need the same privileges as the original 0.1.19 emerge. The agent shell cannot `sudo` without a password.

## Migration Plan

1. In the overlay, add the `-r1` ebuild, remove `witen-warden-bin-0.1.19.ebuild`, refresh the package cache, and drop the old cache file.
2. Sign one overlay commit, `net-analyzer/witen-warden-bin: 0.1.19-r1`.
3. Emerge that revision on the host with `bash-completion` on. Confirm the completion file, `warden 0.1.19`, and a still-disabled service.
4. Inspect a `USE=-bash-completion` install image for the absent completion file. Leave the merged system on the flag-on revision.
5. Rollback is restoring the unrevisioned ebuild and its cache in a later overlay commit. No distfile or config migration. `/etc/witen/warden.toml` is untouched.
