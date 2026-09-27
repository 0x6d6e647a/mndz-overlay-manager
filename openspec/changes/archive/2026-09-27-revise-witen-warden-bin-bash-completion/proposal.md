# Proposal

## Why

`net-analyzer/witen-warden-bin` installs `/usr/share/bash-completion/completions/warden` on every system. The script calls `_init_completion` and is useless without `app-shells/bash-completion`, and the rest of this overlay already gates that kind of file on the global `bash-completion` USE flag. 0.1.19 is already installed, so the fix has to ship as a revision.

## What Changes

- Replace the live overlay ebuild `witen-warden-bin-0.1.19.ebuild` with `witen-warden-bin-0.1.19-r1.ebuild`. The package version stays 0.1.19. Both distfile URLs stay the same, so Manifest `DIST` lines stay the same.
- Add `bash-completion` to `IUSE` with no leading `+`, so the effective value follows profile and `make.conf`. This machine already enables the flag, so the file stays installed here.
- When `bash-completion` is on, install the upstream completion file and depend on `app-shells/bash-completion`. When it is off, do not install that file and do not pull that dependency.
- Update the seeded package spec so the live ebuild name is the `-r1` and bash completion is conditional.

## Non-goals

- No `systemd` or `openrc` USE flags. Both supervisors stay installed on every build.
- No `logrotate` USE flag. The OpenRC logrotate snippet stays installed on every build.
- No `zsh-completion` or `fish-completion` flags, and no generated or translated completion scripts.
- No change to the `iptables` flag, the packaged `backend = "nft"` config, or the hard `nftables` dependency.
- No new upstream PV, and no change to `GitMvAndManifest`. The next version bump still renames the newest ebuild to the bare remote PV and copies the body, including this flag.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `net-analyzer-witen-warden-bin-seed`: The live ebuild is `witen-warden-bin-0.1.19-r1.ebuild`. `IUSE` includes `bash-completion`, and the upstream bash completion file is installed only when that flag is enabled, with a dependency on `app-shells/bash-completion`.

## Impact

- **Overlay repo**: `net-analyzer/witen-warden-bin/`. Remove the unrevisioned 0.1.19 ebuild, add the `-r1`, replace `metadata/md5-cache/net-analyzer/witen-warden-bin-0.1.19` with the `-r1` cache. `metadata.xml` and Manifest `DIST` entries stay.
- **Specs**: `openspec/specs/net-analyzer-witen-warden-bin-seed/spec.md` via this change's delta. `update-apply` stays as it is: apply still does not rewrite the ebuild body.
- **Manager code**: no Haskell change. The Warden apply fixture keeps its own 0.1.17 body and still asserts that a bump does not rewrite `IUSE`.
- **Installed systems**: emerging the revision drops the completion file only when `bash-completion` is off. `warden --version` still reports `0.1.19`.
