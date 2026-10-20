# Tasks

## 1. Manager policy

- [x] 1.1 Register `dev-util/kiro-cli-bin` in `src/Update/Hardcoded.hs`: HttpJson URL `https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json`, field `version`, technique `GitMvAndManifest`, empty `policyLaneArches`. Do not add a body rewrite. Extend `test/Test/Policy.hs` with a `Hardcoded Kiro` case in the shape of `testHardcodedWarden`: `lookupPolicy` returns that HttpJson value, `GitMvAndManifest`, and `[]`, and `lookupHardcoded` matches `resolveSource`. Verify `just coverage 'Hardcoded Kiro'` passes, including that the allowlist is empty and that `kiro-cli-bin` and the bare name `kiro-cli-bin` are the same target with no PV argument.

- [x] 1.2 Add an apply test modeled on `runWardenGitMv` that bumps a fixture `kiro-cli-bin-2.31.1.ebuild` to `2.32.0`, leaves the body byte-for-byte unchanged, and fails the test if the grok-bot commit-feed HTTP hook runs. The fixture body contains the four headless filenames `kirocli-x86_64-linux.tar.xz`, `kirocli-aarch64-linux.tar.xz`, `kirocli-x86_64-linux-musl.tar.xz`, and `kirocli-aarch64-linux-musl.tar.xz`. Verify `just coverage 'Kiro CLI GitMv'` passes and the renamed file is `kiro-cli-bin-2.32.0.ebuild`.

- [x] 1.3 Run `openspec validate add-dev-util-kiro-cli-bin --type change --strict` and `just check`. Verify both exit 0. Do not edit `README.md`, `CONTRIBUTING.md`, or `AGENTS.md`.

## 2. Overlay seed

- [x] 2.1 In `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay`, add `dev-util/kiro-cli-bin/kiro-cli-bin-2.31.1.ebuild` and `metadata.xml` matching `dev-util-kiro-cli-bin-seed`. EAPI 8, `KEYWORDS="-* ~amd64 ~arm64"`, `LICENSE="all-rights-reserved"`, homepage `https://kiro.dev/cli`, no `IUSE` line, `RESTRICT="bindist mirror strip"`, `QA_PREBUILT` on the three `/usr/bin` paths, `S="${WORKDIR}/kirocli"`, and `RDEPEND="elibc_glibc? ( >=sys-libs/glibc-2.34 )"`. `SRC_URI` is the four `elibc_glibc` / `elibc_musl` archives on `https://desktop-release.q.us-east-1.amazonaws.com/${PV}/`. `src_install` installs only `kiro-cli`, `kiro-cli-chat`, and `kiro-cli-term` to `/usr/bin`. `pkg_postinst` elogs `kiro-cli settings app.disableAutoupdates true`. No wrapper, no `KIRO_HOME`, no `KIRO_NO_AUTO_UPDATE`, no `q` or `qchat`, no `install.sh`. `metadata.xml` uses `bugs-to` `https://github.com/kirodotdev/Kiro/issues` and website `https://kiro.dev/cli`, with no GitHub remote id. From the package directory, as the user, run `DISTDIR="${HOME}/.cache/mndz/overlay-manager/distfiles" ebuild kiro-cli-bin-2.31.1.ebuild manifest`, then `egencache --update --repo mndz` with a `--repositories-configuration` whose `mndz` location is the overlay root. Verify the Manifest has four `DIST` lines for the `2.31.1` headless archives and that `metadata/md5-cache/dev-util/kiro-cli-bin-2.31.1` matches the ebuild.

- [x] 2.2 Create one signed local overlay commit whose subject is `dev-util/kiro-cli-bin: 2.31.1` and whose body is empty. Stage the ebuild, `metadata.xml`, Manifest, and md5-cache. Do not push. If pinentry cannot complete, stop and leave the commit for the operator's TTY. Verify `git log -1 --format='%G? %s'` prints `G` and that subject, and `git status` in the package directory is clean.

## 3. Operator loop

- [x] 3.1 Ask the operator to run `sudo emerge -v1 =dev-util/kiro-cli-bin-2.31.1`. Do not run emerge. Verify `kiro-cli --version` prints `kiro-cli 2.31.1`, `kiro-cli-chat --version` prints `kiro-cli-chat 2.31.1`, and `kiro-cli-term --version` prints `figterm 2.31.1`. Do not use `kiro-cli doctor` as the smoke.

- [x] 3.2 Run `just run outdated dev-util/kiro-cli-bin` and `just run outdated kiro-cli-bin`. Verify both print the same move from `2.31.1` to the manifest `version` and exit 0. Verify `just run outdated kiro-cli-bin-2.31.1` exits 1 before package work. `outdated` must not commit.

- [x] 3.3 Ask the operator to run `just run update dev-util/kiro-cli-bin` on their TTY. Do not start it unattended. Verify the new ebuild is `kiro-cli-bin-<feed>.ebuild` where `<feed>` is the manifest version, the `2.31.1` ebuild is still present, the new body still contains the four headless filenames, Manifest and md5-cache match, and the signed commit subject is `dev-util/kiro-cli-bin: <feed>`. Do not push. No assets release is published.

- [x] 3.4 Ask the operator to run `sudo emerge -v1 =dev-util/kiro-cli-bin-<feed>`. Verify the three `--version` commands print `<feed>` (`figterm <feed>` for `kiro-cli-term`).

- [x] 3.5 Ask the operator to run `sudo FEATURES=test emerge -v1 =dev-util/kiro-cli-bin-<feed>`. Do not pass `USE=test`. Verify the emerge completes with an empty test phase and the three `--version` commands still print `<feed>`.

## Workflow follow-up

- After the operator loop is green, sync the delta specs into living specs and archive this change. The seed requirement still names the introduced `kiro-cli-bin-2.31.1.ebuild`. The `2.32.0` apply renamed that file away; nothing pins the old PV, so the tree keeps only `kiro-cli-bin-2.32.0.ebuild`.
- Do not push the overlay. Wait for an explicit go-ahead.
