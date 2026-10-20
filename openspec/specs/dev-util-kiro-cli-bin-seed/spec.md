# dev-util-kiro-cli-bin-seed Specification

## Purpose

Seeded overlay package truth for `dev-util/kiro-cli-bin`: the prebuilt Kiro CLI, its libc-selected headless archives, and the `/usr/bin` install.

## Requirements

### Requirement: Kiro CLI package identity

The overlay SHALL ship `dev-util/kiro-cli-bin` as a prebuilt package. The seed ebuild SHALL be `kiro-cli-bin-2.31.1.ebuild`. `KEYWORDS` SHALL be `-* ~amd64 ~arm64`. `LICENSE` SHALL be `all-rights-reserved`. The homepage SHALL be `https://kiro.dev/cli`.

#### Scenario: Seed ebuild is 2.31.1 for both arches

- **WHEN** the seed `dev-util/kiro-cli-bin` ebuild is inspected
- **THEN** its filename is `kiro-cli-bin-2.31.1.ebuild`
- **AND** `KEYWORDS` is `-* ~amd64 ~arm64`
- **AND** `LICENSE` is `all-rights-reserved`
- **AND** the homepage is `https://kiro.dev/cli`

### Requirement: Headless archives follow the profile libc

`SRC_URI` SHALL use `https://desktop-release.q.us-east-1.amazonaws.com/${PV}/`. `elibc_glibc` SHALL select `kirocli-x86_64-linux.tar.xz` on amd64 and `kirocli-aarch64-linux.tar.xz` on arm64. `elibc_musl` SHALL select `kirocli-x86_64-linux-musl.tar.xz` on amd64 and `kirocli-aarch64-linux-musl.tar.xz` on arm64. The ebuild SHALL NOT list those expand flags in `IUSE`. It SHALL NOT name `kiro-cli.deb`, `kiro-cli.appimage`, or `prod.download.desktop.kiro.dev`.

#### Scenario: glibc amd64 uses the gnu headless archive

- **WHEN** the ebuild `SRC_URI` is inspected
- **THEN** the `elibc_glibc` amd64 URI ends in `${PV}/kirocli-x86_64-linux.tar.xz` on `desktop-release.q.us-east-1.amazonaws.com`
- **AND** the `elibc_glibc` arm64 URI ends in `${PV}/kirocli-aarch64-linux.tar.xz` on that host

#### Scenario: musl arm64 uses the musl headless archive

- **WHEN** the ebuild `SRC_URI` is inspected
- **THEN** the `elibc_musl` amd64 URI ends in `${PV}/kirocli-x86_64-linux-musl.tar.xz`
- **AND** the `elibc_musl` arm64 URI ends in `${PV}/kirocli-aarch64-linux-musl.tar.xz`

#### Scenario: IDE and full CLI packages are absent

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` does not contain `elibc_glibc` or `elibc_musl`
- **AND** the ebuild text does not contain `kiro-cli.deb`, `kiro-cli.appimage`, or `prod.download.desktop.kiro.dev`

### Requirement: Three CLI binaries and no legacy scripts

`src_install` SHALL install `kiro-cli`, `kiro-cli-chat`, and `kiro-cli-term` at `/usr/bin`. The package SHALL NOT install `q` or `qchat`, SHALL NOT run upstream `install.sh`, and SHALL NOT install a wrapper.

#### Scenario: Installed commands are the three ELFs

- **WHEN** the package is installed
- **THEN** `/usr/bin/kiro-cli`, `/usr/bin/kiro-cli-chat`, and `/usr/bin/kiro-cli-term` exist
- **AND** `/usr/bin/q` and `/usr/bin/qchat` are not provided by this package

### Requirement: glibc floor only on the gnu build

When `elibc_glibc` is set, `RDEPEND` SHALL include `>=sys-libs/glibc-2.34`. When `elibc_musl` is set, `RDEPEND` SHALL NOT include `sys-libs/glibc` and SHALL NOT include `sys-libs/musl`.

#### Scenario: Musl adds no libc atom

- **WHEN** the ebuild `RDEPEND` is inspected
- **THEN** `>=sys-libs/glibc-2.34` appears only under `elibc_glibc`
- **AND** `sys-libs/musl` is absent

### Requirement: Autoupdate is an elog, not a home write

`pkg_postinst` SHALL elog `kiro-cli settings app.disableAutoupdates true`. The ebuild SHALL NOT write `~/.kiro/settings/cli.json` and SHALL NOT assign `KIRO_HOME` or `KIRO_NO_AUTO_UPDATE`.

#### Scenario: Postinst names the setting and does not export it

- **WHEN** the ebuild is inspected
- **THEN** `pkg_postinst` includes `kiro-cli settings app.disableAutoupdates true`
- **AND** the ebuild does not assign `KIRO_HOME` or `KIRO_NO_AUTO_UPDATE`

### Requirement: Prebuilt package has no test phase

The ebuild SHALL NOT define `src_test` and SHALL NOT add `test` to `IUSE`. `RESTRICT` SHALL include `bindist`, `mirror`, and `strip`. `QA_PREBUILT` SHALL cover `/usr/bin/kiro-cli`, `/usr/bin/kiro-cli-chat`, and `/usr/bin/kiro-cli-term`.

#### Scenario: No test USE

- **WHEN** the ebuild is inspected
- **THEN** it has no `src_test`
- **AND** `IUSE` does not include `test`
- **AND** `RESTRICT` includes `bindist`, `mirror`, and `strip`
- **AND** `QA_PREBUILT` names those three `/usr/bin` paths

### Requirement: Upstream metadata points at the CLI

`metadata.xml` SHALL set `bugs-to` to `https://github.com/kirodotdev/Kiro/issues` and a website remote id of `https://kiro.dev/cli`. It SHALL NOT set a GitHub remote id.

#### Scenario: Issue tracker without a source remote

- **WHEN** `metadata.xml` is inspected
- **THEN** `bugs-to` is `https://github.com/kirodotdev/Kiro/issues`
- **AND** the website remote id is `https://kiro.dev/cli`
- **AND** no `remote-id` has type `github`
