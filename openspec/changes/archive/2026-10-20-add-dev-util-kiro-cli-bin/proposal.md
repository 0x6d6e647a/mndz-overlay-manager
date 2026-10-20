# Proposal

## Why

Kiro CLI is a closed-source prebuilt the overlay does not ship, so `outdated` and `update` cannot track it. A seed one release behind the current feed makes the first bump the proof that `GitMvAndManifest` can move it. Gentoo musl profiles need a different upstream archive than glibc profiles, and the profile already selects that archive.

## What Changes

- Seed `dev-util/kiro-cli-bin` at PV `2.31.1` with `KEYWORDS="-* ~amd64 ~arm64"` and `LICENSE="all-rights-reserved"`. The first automated bump target, while the feed still reports it, is `2.32.0`.
- Version source is one HttpJson feed: `https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json`, field `version`. Technique is `GitMvAndManifest` with an empty arch allowlist. Apply renames the ebuild and does not rewrite the body.
- `SRC_URI` uses `${PV}` on that same host. glibc profiles take `kirocli-x86_64-linux.tar.xz` and `kirocli-aarch64-linux.tar.xz` (`elibc_glibc`). Musl profiles take `kirocli-x86_64-linux-musl.tar.xz` and `kirocli-aarch64-linux-musl.tar.xz` (`elibc_musl`). There is no custom `musl` USE flag and no `IUSE` entry for the expand flags.
- Install `kiro-cli`, `kiro-cli-chat`, and `kiro-cli-term` to `/usr/bin`. Do not install `q` or `qchat`, do not run upstream `install.sh`, and do not wrap the binaries. `pkg_postinst` elogs `kiro-cli settings app.disableAutoupdates true`. The ebuild does not write `~/.kiro/settings/cli.json`.
- The package is prebuilt and exempt from `IUSE=test`. No assets release. No README change: the operator CLI is unchanged.

## Non-goals

- Packaging the Kiro IDE (`prod.download.desktop.kiro.dev`, binary `kiro`, version train 1.4.x).
- Using `kiro-cli.deb`, `kiro-cli.appimage`, the macOS dmg, the Windows msi, rpm, zip, tar.gz, or tar.zst as `SRC_URI`.
- A wrapper, a `KIRO_HOME` override, or any install-time write of `app.disableAutoupdates`.
- Building `aws/amazon-q-developer-cli` or treating `kirodotdev/Kiro` as source.
- Shell-completion USE flags, an `alsa`/`wayland` dependency, or installing the legacy `q` / `qchat` scripts.
- A custom `musl` USE flag that an operator would toggle by hand.
- Pushing the overlay. Commits stay local until an explicit go-ahead. The operator runs `emerge` and the signed `update`.

## Capabilities

### New Capabilities

- `dev-util-kiro-cli-bin-seed`: Seed identity, libc-selected distfiles, `/usr/bin` layout, glibc floor, and the autoupdate elog.

### Modified Capabilities

- `update-source`: `dev-util/kiro-cli-bin` maps to the desktop-release manifest HttpJson `version` field.
- `update-apply`: The package is `GitMvAndManifest`, empty arch allowlist, not an image or wait-edge provider, and a bump preserves the ebuild body.
- `overlay-test-use`: `dev-util/kiro-cli-bin` is exempt from `IUSE=test`.

## Impact

- Manager: one hardcoded policy entry and a policy test. No new fetch technique. `just check` is the manager gate.
- Overlay: `dev-util/kiro-cli-bin` ebuild, `metadata.xml`, Manifest, and md5-cache. The seed commit must exist before `update`. `ebuild manifest` fetches every conditional archive (glibc and musl, both arches).
- Operator: emerge the seed, smoke the three binaries, then `outdated` and `update` on a TTY, then emerge the bump. `FEATURES=test` still has an empty test phase.
