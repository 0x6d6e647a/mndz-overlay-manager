# Proposal

## Why

Upstream Kiro CLI 3.x no longer publishes the `tar.xz` headless archives or the separate `kiro-cli-chat` and `kiro-cli-term` binaries. `GitMvAndManifest` only renames the ebuild, so the 2.37.1 body cannot move forward: manifest fetch has nothing to hash, and `src_install` would miss two paths. A 3.0.0 seed with the new body makes the following bump the proof that rename-and-manifest still works.

## What Changes

- Replace `kiro-cli-bin-2.37.1.ebuild` with `kiro-cli-bin-3.0.0.ebuild` in one overlay commit. The package directory keeps a single ebuild. The live feed's `version` at the time of this proposal is `3.1.0`; the first automated bump target, while the feed still reports it, is `3.1.0`.
- **BREAKING**: install only `kiro-cli` to `/usr/bin`. Do not install `kiro-cli-chat`, `kiro-cli-term`, `q`, or `qchat`, and do not add a wrapper.
- `SRC_URI` keeps `${PV}` on `https://desktop-release.q.us-east-1.amazonaws.com/` and the `elibc_glibc` / `elibc_musl` split. The four headless names change suffix from `.tar.xz` to `.tar.gz`. Distfile names stay `kirocli-${PV}-…` so one Manifest can record them.
- `QA_PREBUILT` covers `/usr/bin/kiro-cli` only. `RESTRICT`, the glibc floor, the autoupdate elog, `metadata.xml`, and the absence of `IUSE` stay.
- No manager technique change and no assets release. The operator emerges and smokes `3.0.0` before `outdated` and `update`.

## Non-goals

- Teaching `GitMvAndManifest` to rewrite `SRC_URI` or `src_install`.
- A `kiro-cli-chat` wrapper that execs `kiro-cli chat`, or any install of `kiro-cli-term` / figterm.
- Using `tar.zst`, zip, rpm, deb, or `kiro-cli.appimage` as `SRC_URI`.
- Packaging the Kiro IDE, or changing the HttpJson URL or version field.
- Adding `IUSE`, including `test`.
- Pushing the overlay. Commits stay local until an explicit go-ahead. The operator runs `emerge` and the signed `update`.

## Capabilities

### New Capabilities

### Modified Capabilities

- `dev-util-kiro-cli-bin-seed`: Headless archives are `.tar.gz`. The install and `QA_PREBUILT` set is `kiro-cli` only.

## Impact

- Overlay: replace `dev-util/kiro-cli-bin/kiro-cli-bin-2.37.1.ebuild` and its md5-cache entry with the `3.0.0` pair, and regenerate `Manifest`. `metadata.xml` stays. The seed commit exists before `update`.
- Installed system: `/usr/bin/kiro-cli-chat` and `/usr/bin/kiro-cli-term` are no longer owned by this package after the `3.0.0` emerge.
- Manager: no Haskell change. `outdated` and `update` already resolve `dev-util/kiro-cli-bin`. The bump commit is the usual signed `dev-util/kiro-cli-bin: <feed>`.
- Operator: emerge `=dev-util/kiro-cli-bin-3.0.0`, smoke `kiro-cli --version`, then `outdated` and `update` on a TTY, then emerge and smoke the bumped PV, then `FEATURES=test` without `USE=test`.
