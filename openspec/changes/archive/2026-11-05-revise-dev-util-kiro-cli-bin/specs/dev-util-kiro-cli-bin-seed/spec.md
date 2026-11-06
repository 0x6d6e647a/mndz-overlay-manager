## MODIFIED Requirements

### Requirement: Headless archives follow the profile libc

`SRC_URI` SHALL use `https://desktop-release.q.us-east-1.amazonaws.com/${PV}/`. `elibc_glibc` SHALL select `kirocli-x86_64-linux.tar.gz` on amd64 and `kirocli-aarch64-linux.tar.gz` on arm64. `elibc_musl` SHALL select `kirocli-x86_64-linux-musl.tar.gz` on amd64 and `kirocli-aarch64-linux-musl.tar.gz` on arm64. The ebuild SHALL NOT list those expand flags in `IUSE`. It SHALL NOT name `kiro-cli.deb`, `kiro-cli.appimage`, or `prod.download.desktop.kiro.dev`.

#### Scenario: glibc amd64 uses the gnu headless archive

- **WHEN** the ebuild `SRC_URI` is inspected
- **THEN** the `elibc_glibc` amd64 URI ends in `${PV}/kirocli-x86_64-linux.tar.gz` on `desktop-release.q.us-east-1.amazonaws.com`
- **AND** the `elibc_glibc` arm64 URI ends in `${PV}/kirocli-aarch64-linux.tar.gz` on that host

#### Scenario: musl arm64 uses the musl headless archive

- **WHEN** the ebuild `SRC_URI` is inspected
- **THEN** the `elibc_musl` amd64 URI ends in `${PV}/kirocli-x86_64-linux-musl.tar.gz`
- **AND** the `elibc_musl` arm64 URI ends in `${PV}/kirocli-aarch64-linux-musl.tar.gz`

#### Scenario: IDE and full CLI packages are absent

- **WHEN** the ebuild is inspected
- **THEN** `IUSE` does not contain `elibc_glibc` or `elibc_musl`
- **AND** the ebuild text does not contain `kiro-cli.deb`, `kiro-cli.appimage`, or `prod.download.desktop.kiro.dev`

### Requirement: Prebuilt package has no test phase

The ebuild SHALL NOT define `src_test` and SHALL NOT add `test` to `IUSE`. `RESTRICT` SHALL include `bindist`, `mirror`, and `strip`. `QA_PREBUILT` SHALL cover `/usr/bin/kiro-cli`.

#### Scenario: No test USE

- **WHEN** the ebuild is inspected
- **THEN** it has no `src_test`
- **AND** `IUSE` does not include `test`
- **AND** `RESTRICT` includes `bindist`, `mirror`, and `strip`
- **AND** `QA_PREBUILT` names `/usr/bin/kiro-cli`
- **AND** `QA_PREBUILT` does not name `kiro-cli-chat` or `kiro-cli-term`

## REMOVED Requirements

### Requirement: Three CLI binaries and no legacy scripts

**Reason:** Upstream 3.x headless archives ship one ELF, `kiro-cli`. `chat` is a subcommand of that binary. `kiro-cli-term` is not in the archive and is not a subcommand.

**Migration:** Invoke chat as `kiro-cli chat`. There is no packaged replacement for `kiro-cli-term`. The package still does not install `q`, `qchat`, a wrapper, or upstream `install.sh`.

## ADDED Requirements

### Requirement: One CLI binary and no legacy names

`src_install` SHALL install `kiro-cli` at `/usr/bin` and SHALL NOT install `kiro-cli-chat`, `kiro-cli-term`, `q`, or `qchat`. The package SHALL NOT run upstream `install.sh` and SHALL NOT install a wrapper.

#### Scenario: Installed command is kiro-cli

- **WHEN** the package is installed
- **THEN** `/usr/bin/kiro-cli` exists
- **AND** this package does not provide `/usr/bin/kiro-cli-chat`, `/usr/bin/kiro-cli-term`, `/usr/bin/q`, or `/usr/bin/qchat`

#### Scenario: Ebuild does not wrap or run install.sh

- **WHEN** the ebuild is inspected
- **THEN** it does not run `install.sh`
- **AND** it does not install a wrapper
