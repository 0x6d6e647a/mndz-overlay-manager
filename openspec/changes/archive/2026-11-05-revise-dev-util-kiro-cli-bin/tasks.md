# Tasks

## 1. Spec gate

- [x] 1.1 Run `openspec validate revise-dev-util-kiro-cli-bin --type change --strict` and `just check`. Verify both exit 0. Do not edit manager Haskell, `README.md`, `CONTRIBUTING.md`, or `AGENTS.md`.

## 2. Overlay seed

- [x] 2.1 In `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay`, replace `dev-util/kiro-cli-bin/kiro-cli-bin-2.37.1.ebuild` with `kiro-cli-bin-3.0.0.ebuild`. Keep EAPI 8, `KEYWORDS="-* ~amd64 ~arm64"`, `LICENSE="all-rights-reserved"`, homepage `https://kiro.dev/cli`, no `IUSE` line, `RESTRICT="bindist mirror strip"`, `S="${WORKDIR}/kirocli"`, and `RDEPEND="elibc_glibc? ( >=sys-libs/glibc-2.34 )"`. `SRC_URI` is the four `elibc_glibc` / `elibc_musl` `tar.gz` archives on `https://desktop-release.q.us-east-1.amazonaws.com/${PV}/`, each renamed to `kirocli-${PV}-…tar.gz`. `src_install` installs only `bin/kiro-cli` to `/usr/bin`. `QA_PREBUILT` is `usr/bin/kiro-cli`. `pkg_postinst` elogs `kiro-cli settings app.disableAutoupdates true`. No wrapper, no `KIRO_HOME`, no `KIRO_NO_AUTO_UPDATE`, no `q` or `qchat`, no `kiro-cli-chat`, no `kiro-cli-term`, no `install.sh`. Leave `metadata.xml` unchanged. From the package directory, as the user, run `DISTDIR="${HOME}/.cache/mndz/overlay-manager/distfiles" ebuild kiro-cli-bin-3.0.0.ebuild manifest`, then `egencache --update --repo mndz` with a `--repositories-configuration` whose `mndz` location is the overlay root. Verify the package directory has no `kiro-cli-bin-2.37.1.ebuild`, the Manifest has four `DIST` lines for the `3.0.0` `.tar.gz` archives and no `.tar.xz` lines, and `metadata/md5-cache/dev-util/kiro-cli-bin-3.0.0` matches the ebuild.

- [x] 2.2 Create one signed local overlay commit whose subject is `dev-util/kiro-cli-bin: 3.0.0` and whose body is empty. Stage the ebuild rename, the Manifest, the new md5-cache, and the removal of `metadata/md5-cache/dev-util/kiro-cli-bin-2.37.1`. Do not stage `metadata.xml`. Do not push. If pinentry cannot complete, stop and leave the commit for the operator's TTY. Verify `git log -1 --format='%G? %s'` prints `G` and that subject, and `git status` in the package directory is clean.

## 3. Operator loop

- [x] 3.1 Ask the operator to run `sudo emerge -v1 =dev-util/kiro-cli-bin-3.0.0`. Do not run emerge. Verify `kiro-cli --version` prints `kiro-cli 3.0.0`. Verify `kiro-cli-chat` and `kiro-cli-term` are not provided by this package. Do not use `kiro-cli doctor` as the smoke.

- [x] 3.2 Run `just run outdated dev-util/kiro-cli-bin` and `just run outdated kiro-cli-bin`. Verify both print the same move from `3.0.0` to the manifest `version` and exit 0. Verify `just run outdated kiro-cli-bin-3.0.0` exits 1 before package work. `outdated` must not commit.

- [x] 3.3 Ask the operator to run `just run update dev-util/kiro-cli-bin` on their TTY. Do not start it unattended. If the live manifest `version` is not `3.1.0`, stop and confirm that version's four headless `tar.gz` archives still unpack to `kirocli/bin/kiro-cli` only. Verify the only ebuild is `kiro-cli-bin-<feed>.ebuild`, `kiro-cli-bin-3.0.0.ebuild` is gone, the body still contains the four `.tar.gz` filenames and `doexe bin/kiro-cli`, Manifest and md5-cache match, and the signed commit subject is `dev-util/kiro-cli-bin: <feed>`. Do not push. No assets release is published.

- [x] 3.4 Ask the operator to run `sudo emerge -v1 =dev-util/kiro-cli-bin-<feed>`. Verify `kiro-cli --version` prints `kiro-cli <feed>`.

- [x] 3.5 Ask the operator to run `sudo FEATURES=test emerge -v1 =dev-util/kiro-cli-bin-<feed>`. Do not pass `USE=test`. Verify the emerge completes with an empty test phase and `kiro-cli --version` still prints `kiro-cli <feed>`.

## Workflow follow-up

- After the operator loop is green, sync the delta specs into living specs and archive this change. The requirement that names the introduced `kiro-cli-bin-2.31.1.ebuild` stays. Nothing pins an older PV, so the tree keeps only `kiro-cli-bin-<feed>.ebuild`.
- Do not push the overlay. Wait for an explicit go-ahead.
