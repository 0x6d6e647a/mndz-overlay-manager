# Design

## Context

See `proposal.md` for why this package is added. `GitMvAndManifest` already renames the newest ebuild to the remote PV, runs `ebuild manifest` and package `egencache`, and signs one overlay commit. The only body rewrite on that path is `dev-util/grok-bot-bin`'s commit pin. `policyLaneArches` is empty for the other prebuilt bins, so `KEYWORDS` live in the ebuild and survive the rename. `ebuild manifest` digests every conditional `SRC_URI`, including ones the host profile does not enable.

The CLI manifest at `https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json` is a JSON object whose top-level `version` was `2.32.0` on 2026-10-20. That object lists headless `kirocli-*-linux.tar.xz` archives and, separately, variant `full` files named `kiro-cli.deb` and `kiro-cli.appimage`. The IDE is a different host and version train (`prod.download.desktop.kiro.dev`, `1.4.5`, `kiro-ide-…tar.gz`).

## Goals / Non-Goals

**Goals:**

- One policy entry and one policy test. No new fetch code.
- An ebuild body that a rename can carry from `2.31.1` to the manifest version.
- Profile `ELIBC` chooses the archive. A hand-toggled `musl` USE flag does not.

**Non-Goals:**

- A Nix-style FHS wrap. The musl build is static-pie and the gnu build's interpreter is `/lib64/ld-linux-x86-64.so.2`.
- Teaching `GitMv` to pick a manifest `download` path. The ebuild filename is the pin.
- Changing `project-docs`. The operator CLI is unchanged.

## Decisions

- **HttpJson, one URL, field `version`, technique `GitMvAndManifest`, empty allowlist.** Same shape as `dev-util/grok-bot-bin` without the second feed and without the commit rewrite. Alternative: a plain Http body — the feed is a JSON object, and HttpJson already requires a top-level string field. Alternative: GitHub tags — `kirodotdev/Kiro` is an issue tracker, and `aws/amazon-q-developer-cli` is the abandoned predecessor.

- **Pin the headless filename on the manifest host.** `SRC_URI` is `https://desktop-release.q.us-east-1.amazonaws.com/${PV}/` plus one of the four names below. Sharing the host with the version feed is convenience. The filename is what excludes the IDE and the variant `full` deb and AppImage. A later bump that fetched "whatever the manifest calls full" would be the mistake; `GitMv` only supplies the version string. Alternative: `prod.download.cli.kiro.dev` — not used. The manifest's own `download` paths are relative to the desktop-release host.

- **`elibc_glibc` / `elibc_musl`, not `IUSE=musl`.** Tree packages such as `www-apps/jellyfin-bin` use the same positive pair and do not list the expand flags in `IUSE`. Profiles set `ELIBC`, so a musl system cannot fetch the gnu archive and a glibc system cannot fetch the musl archive. The x86_64 musl `2.32.0` archive (135416512 bytes, sha256 `7980be972eb5c6c6924761b0f6412f6574a6943bef887bd54b254565e87237b9`, matching the manifest) unpacks to the same `kirocli/bin/` names as the gnu archive. `file` reports all three as static-pie, `ldd` reports statically linked, and they have no `DT_NEEDED`. `kiro-cli --version` on this glibc host printed `kiro-cli 2.32.0`. `BUILD-INFO` says `x86_64-unknown-linux-musl`. So the musl build needs no `sys-libs/musl` atom, and `>=sys-libs/glibc-2.34` stays under `elibc_glibc` only. Alternative: ship the static musl build on every profile — it runs on glibc, and it would drop the dynamic gnu build that upstream documents for glibc 2.34+ and that `kiro-cli update` itself downloads. Alternative: a custom `musl` flag — an operator can turn it on for glibc or leave it off for musl.

- **Install the three ELFs to `/usr/bin`. No wrapper.** `kiro-cli update` replaces a binary only when `current_exe()` is `$HOME/.local/bin`. From an unpacked `2.31.1` that check refused before download and named the headless `kirocli-x86_64-linux.tar.zst`. The same binary copied into an isolated `~/.local/bin` did replace itself with `2.32.0`. A wrapper whose ELF resolved there would be a supported update target. `KIRO_NO_AUTO_UPDATE` does not set `app.disableAutoupdates` (the settings query still reports no value) and upstream documents it for Windows. `pkg_postinst` elogs `kiro-cli settings app.disableAutoupdates true`. `q` and `qchat` hardcode `$HOME/.local/bin/kiro-cli` and collide with `app-portage/portage-utils`, so they stay out of the image. Upstream `install.sh` is what places binaries in `~/.local/bin`; the ebuild does not run it.

- **Seed the final body at `2.31.1`, with no `-r1`.** Those four archives returned HTTP 200 on 2026-10-20 (gnu amd64 138215016 bytes, gnu arm64 131929828, musl amd64 142297528, musl arm64 134005172). Content edits after that PV has been merged would be a revision bump. The first body is the merged body.

- **No assets publish.** There is no deps tarball. The materialize image does not emerge this package.

## Risks / Trade-offs

- [Risk] Each `update` runs `ebuild manifest`, which fetches all four conditional archives. At `2.32.0` that is 131141636 + 124741532 + 135416512 + 126980280 bytes. → Accepted. An emerge on one profile fetches one archive. A custom USE flag would not shrink the manifest fetch.
- [Risk] The aarch64 gnu and musl archives were not unpacked. → The ebuild uses the same `S="${WORKDIR}/kirocli"` as the unpacked amd64 trees. A different layout fails the emerge instead of installing the wrong tree.
- [Risk] `kiro-cli-chat` and `kiro-cli-term` can still nag, and a user who later copies a binary into `~/.local/bin` can self-update. `kiro-cli init` and the dotfiles integration prepend that directory. → The elog is the chosen control. The package does not write `cli.json`.
- [Risk] The chat binary mentions bun and libbz2 in strings and does not `DT_NEEDED` them. A runtime extract could show up after install. → No extra RDEPEND until an emerge or smoke shows a missing library. Do not add it on strings alone.
- [Risk] Upstream drops `2.31.1` or renames the headless file. The install docs say the downloads page offers only the latest. → Seed while the four `2.31.1` URLs answer 200. A missing archive fails `ebuild manifest`. A rename fails the next manifest instead of switching to the deb.
- [Risk] The manifest moves past `2.32.0` before `update` runs. → The bump target is the feed's `version`, not a hardcoded `2.32.0`. The body check is the four filename templates.

## Migration Plan

Add the overlay package and the policy entry. The seed commit includes the ebuild, Manifest, `metadata.xml`, and md5-cache, and stays local. The operator emerges `=dev-util/kiro-cli-bin-2.31.1` and smokes the three `--version` commands. `outdated` then `update` on a TTY. The operator emerges the bumped ebuild, smokes again, then emerges with `FEATURES=test` and smokes again. Rollback is dropping the local overlay commits and unmerging the package. Do not push.
