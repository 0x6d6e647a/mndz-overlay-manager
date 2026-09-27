# Proposal: add `dev-util/grok-bot-bin`

## Why

Grok Bot, the desktop agent at https://x.ai/bot, is not in the mndz overlay, and the manager cannot bump it. Linux builds are published, but the stable feed is JSON and the download URL embeds a commit SHA, so a plain-text Http source plus a rename-only manifest bump cannot see a new release or fetch it.

## What Changes

- Seed `dev-util/grok-bot-bin` at PV **0.61.0** (commit `47a9d1df3a7d37aaa53d206ab2d1f9159a336223`) for **amd64 and arm64**. The ebuild unpacks the upstream `.deb` from `downloads.cursor.com`, installs `/opt/Grok Bot` and a `/usr/bin/grok-bot` symlink, and installs the desktop file, icons, and `sand://` / `grokbot://` handlers. It does not run the Debian `postinst` and does not install `/usr/bin/sand`.
- `LICENSE="all-rights-reserved"`. `IUSE` defaults `wayland`, `pulseaudio`, and `libnotify` on, and `suid` and `apparmor` off. libsecret and Cups are hard dependencies. No `--no-sandbox`. `chrome-sandbox` stays mode `0755` unless `suid` is on.
- Add the manager policy: `dev-util/grok-bot-bin` → technique `GitMvAndManifest`, source the Cursor stable download feed for `linux-x64` and `linux-arm64`. Version comparison uses the feed's `version`. Apply rewrites `GROK_BOT_COMMIT` from `commitSha` before `ebuild manifest`, then renames the ebuild. Both arches must report the same version and the same commit, and each `debUrl` must match `grok-bot_${PV}_<arch>.deb`. A mismatch hard-fails that package.
- The package is prebuilt and has no `src_test`. It joins the existing prebuilt exemption from the `IUSE=test` convention.
- Acceptance of the bump waits for the next upstream release. `outdated grok-bot-bin` then reports that version, and `update grok-bot-bin` rewrites the commit, renames the ebuild, and regenerates the Manifest. There is no older seed PV.

PV selection stays planner-owned. Package targets remain `category/package` tokens. 0.61.0 is seed product truth only.

## Capabilities

### New Capabilities

- `dev-util-grok-bot-bin-seed`: seeded overlay package truth for `dev-util/grok-bot-bin` at PV 0.61.0 — identity, commit-pinned `.deb` `SRC_URI` for both arches, install layout, USE flags, license, and the operator acceptance that the bump itself waits for the next release.

### Modified Capabilities

- `update-source`: the update-source model gains a JSON HTTP feed whose version and commit come from named fields, not from a plain-text body. `dev-util/grok-bot-bin` maps to the Cursor stable download feed.
- `update-apply`: `dev-util/grok-bot-bin` uses `GitMvAndManifest`, and that apply rewrites `GROK_BOT_COMMIT` from the feed before manifest generation. A feed whose arches disagree, or whose `debUrl` does not match the ebuild filename template, hard-fails the package.
- `overlay-test-use`: `dev-util/grok-bot-bin` joins `bun-bin`, `deno-bin`, and `grok-build-bin` on the prebuilt exemption from `IUSE=test`.

## Impact

- **Manager code**: one policy entry; a JSON feed fetch that returns a version for comparison and a commit for apply; a `GROK_BOT_COMMIT` rewrite on the GitMv path before `ebuild manifest`; policy, fetch, and apply tests. No CLI, materialize-image, or assets-publish changes.
- **Overlay repo**: `dev-util/grok-bot-bin/grok-bot-bin-0.61.0.ebuild`, `metadata.xml`, `Manifest`, md5-cache; signed overlay commit when the operator runs the publish. The next `update` replaces that ebuild with the newer PV.
- **Specs**: new `dev-util-grok-bot-bin-seed`; deltas on `update-source`, `update-apply`, and `overlay-test-use`.
- **Docs**: no operator CLI, config, quality-pipeline, or agent-process change, so README, CONTRIBUTING, and AGENTS stay as they are.

## Non-goals

- No `DepsAndAssets` technique and no republish of the `.deb` into `mndz-overlay-assets`. The distfile is fetched from Cursor at manifest time.
- No seeding of 0.59.1 or 0.58.0. Those pool builds exist, and this change does not use them.
- No `/usr/bin/sand` symlink. `sand://` is a scheme on the `grok-bot` desktop file.
- No `--no-sandbox` wrapper flag, and no setuid `chrome-sandbox` by default.
- No `appindicator` USE and no `app.asar` tray patch. Upstream does not reference `libappindicator`.
- No replacement of the bundled Electron with a system Electron.
- No `src_test`, and no addition of this package to the materialize image.
- No apt source, signing key, or `update-alternatives` from the Debian maintainer scripts.
- No CLI version pins.
