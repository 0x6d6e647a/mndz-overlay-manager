# Proposal

## Why

Kiro IDE is a closed-source desktop editor the overlay does not ship, so `outdated` and `update` cannot track it. It is a different host and version train from `dev-util/kiro-cli-bin`. A seed one stable release behind the current feed makes the first bump the proof that `GitMvAndManifest` can move it.

## What Changes

- Seed `dev-util/kiro-ide-bin` at PV `1.4.5` with `KEYWORDS="-* ~amd64 ~arm64"` and `LICENSE="all-rights-reserved"`. On 2026-10-20 the stable feed reported `1.4.10`. Stable tarballs for `1.4.6` through `1.4.9` were absent, so `1.4.5` is the previous published stable archive.
- Version source is HttpJson on both stable metadata URLs, field `currentRelease`. The two documents must agree. Technique is `GitMvAndManifest` with an empty arch allowlist. Apply renames the ebuild and does not rewrite the body.
- `SRC_URI` uses the signed stable `tar.gz` on `prod.download.desktop.kiro.dev` for `linux-x64` and `linux-arm64`, with `${PV}` in the path and the filename. There is no musl archive.
- Install the unpacked `Kiro/` tree at `/usr/share/kiro` and symlink `/usr/bin/kiro` to `bin/kiro`. Install a desktop entry, the bundled 1024 icon, and the upstream bash and zsh completions. Install `/etc/kiro/policy.json` with `UpdateMode` set to `none`.
- `IUSE` is `+command-sandbox microsoft-auth`. `command-sandbox` depends on `sys-apps/bubblewrap` and `net-misc/socat`. `microsoft-auth` keeps the bundled Microsoft sign-in extension and its webkit-gtk dependency. `chrome-sandbox` stays mode `0755`.
- The package is prebuilt and exempt from `IUSE=test`. No assets release. No README change: the operator CLI is unchanged.

## Non-goals

- Changing `dev-util/kiro-cli-bin`, packaging Kiro Crew, or tracking the insider channel.
- A `.deb`, `.rpm`, dmg, or AppImage `SRC_URI`, a musl archive, or a hand-toggled musl flag.
- `fperms 4755` on `chrome-sandbox`, or `--no-sandbox` in the desktop entry.
- Writing `~/.kiro`, `sandbox.json`, or any edit of `product.json`.
- `IUSE` flags for wayland, egl, kerberos, alsa, cups, or a system ripgrep.
- Building from `kirodotdev/Kiro`. That repository is the issue tracker.
- Pushing the overlay. Commits stay local until an explicit go-ahead. The operator runs `emerge` and the signed `update`.

## Capabilities

### New Capabilities

- `dev-util-kiro-ide-bin-seed`: Seed identity, stable tar.gz distfiles, `/usr/share/kiro` layout, USE flags, update policy file, and the prebuilt test exemption.

### Modified Capabilities

- `update-source`: `dev-util/kiro-ide-bin` maps to the two stable metadata HttpJson documents, field `currentRelease`.
- `update-apply`: The package is `GitMvAndManifest`, empty arch allowlist, not an image or wait-edge provider, and a bump preserves the ebuild body.
- `overlay-test-use`: `dev-util/kiro-ide-bin` is exempt from `IUSE=test`.

## Impact

- Manager: one hardcoded policy entry, a policy test, and an apply test. No new fetch technique. `just check` is the manager gate.
- Overlay: `dev-util/kiro-ide-bin` ebuild, `metadata.xml`, Manifest, and md5-cache. The seed commit must exist before `update`. `ebuild manifest` fetches both arch tarballs.
- Operator: emerge the seed, smoke `kiro --version`, then `outdated` and `update` on a TTY, then emerge the bump and smoke again. `FEATURES=test` still has an empty test phase. This host can smoke amd64 only.
