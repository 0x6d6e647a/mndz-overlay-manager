# dev-util-kiro-ide-bin-seed Specification

## Purpose

Seeded overlay package truth for `dev-util/kiro-ide-bin`: the prebuilt Kiro IDE, its stable Linux tarballs, and the `/usr/share/kiro` install.

## Requirements

### Requirement: Kiro IDE package identity

The overlay SHALL ship `dev-util/kiro-ide-bin` as a prebuilt package. The seed ebuild SHALL be `kiro-ide-bin-1.4.5.ebuild`. `KEYWORDS` SHALL be `-* ~amd64 ~arm64`. `LICENSE` SHALL be `all-rights-reserved`. The homepage SHALL be `https://kiro.dev/`. `EAPI` SHALL be `8` and `SLOT` SHALL be `0`.

#### Scenario: Seed ebuild is 1.4.5 for both arches

- **WHEN** the seed `dev-util/kiro-ide-bin` ebuild is inspected
- **THEN** its filename is `kiro-ide-bin-1.4.5.ebuild`
- **AND** `KEYWORDS` is `-* ~amd64 ~arm64`
- **AND** `LICENSE` is `all-rights-reserved`
- **AND** the homepage is `https://kiro.dev/`
- **AND** `EAPI` is `8` and `SLOT` is `0`

### Requirement: Stable tarballs for amd64 and arm64

`SRC_URI` SHALL use `https://prod.download.desktop.kiro.dev/releases/stable/` with `${PV}` in the path. amd64 SHALL select `linux-x64/signed/${PV}/tar/kiro-ide-${PV}-stable-linux-x64.tar.gz`. arm64 SHALL select `linux-arm64/signed/${PV}/tar/kiro-ide-${PV}-stable-linux-arm64.tar.gz`. The ebuild SHALL NOT name a musl archive, a `.deb`, a `.rpm`, an AppImage, or a dmg.

#### Scenario: Both arches use the signed stable tar.gz

- **WHEN** the ebuild `SRC_URI` is inspected
- **THEN** the amd64 URI is `https://prod.download.desktop.kiro.dev/releases/stable/linux-x64/signed/${PV}/tar/kiro-ide-${PV}-stable-linux-x64.tar.gz`
- **AND** the arm64 URI is `https://prod.download.desktop.kiro.dev/releases/stable/linux-arm64/signed/${PV}/tar/kiro-ide-${PV}-stable-linux-arm64.tar.gz`
- **AND** the ebuild text does not name a musl archive, `.deb`, `.rpm`, AppImage, or dmg

### Requirement: FHS tree and command symlink

The package SHALL install the unpacked `Kiro/` tree at `/usr/share/kiro` and SHALL symlink `/usr/bin/kiro` to `/usr/share/kiro/bin/kiro`. It SHALL NOT install under `/opt` and SHALL NOT provide `/usr/bin/kiro-cli`.

#### Scenario: The editor command is the share-tree wrapper

- **WHEN** the package is installed
- **THEN** `/usr/share/kiro` contains the unpacked `Kiro/` tree
- **AND** `/usr/bin/kiro` is a symlink to `/usr/share/kiro/bin/kiro`
- **AND** the package does not install under `/opt` and does not provide `/usr/bin/kiro-cli`

### Requirement: Version command prints PV

An installed `/usr/bin/kiro --version` SHALL exit 0, and its first line SHALL equal the package PV.

#### Scenario: Smoke matches the installed PV

- **WHEN** `/usr/bin/kiro --version` runs for an installed package
- **THEN** the process exits 0
- **AND** the first line of output equals that package's PV

### Requirement: Desktop entry, icon, and completions

The package SHALL install a desktop entry with `Icon=kiro` and mime type `x-scheme-handler/kiro`, the bundled 1024 icon as `kiro`, the upstream bash completion, and the upstream zsh completion `_kiro`. `RDEPEND` SHALL include `app-shells/bash-completion` and SHALL NOT include a zsh atom. The desktop entry SHALL NOT pass `--no-sandbox`.

#### Scenario: Launcher and completions are installed

- **WHEN** the package is installed
- **THEN** a desktop entry names `Icon=kiro` and `x-scheme-handler/kiro`
- **AND** the 1024 icon is installed as `kiro`
- **AND** the bash completion and `/usr/share/zsh/site-functions/_kiro` are installed
- **AND** `RDEPEND` includes `app-shells/bash-completion` and does not include a zsh atom
- **AND** the desktop entry does not contain `--no-sandbox`

### Requirement: Managed update policy file

The package SHALL install `/etc/kiro/policy.json` as a JSON object whose `UpdateMode` value is `none`. It SHALL NOT write `~/.kiro`, SHALL NOT write `sandbox.json`, SHALL NOT edit `product.json`, and SHALL NOT install `/etc/kiro/managed-settings.json`.

#### Scenario: UpdateMode none is the only managed policy

- **WHEN** the package is installed
- **THEN** `/etc/kiro/policy.json` parses as a JSON object whose `UpdateMode` is `none`
- **AND** the package does not write `~/.kiro` or `sandbox.json`
- **AND** the package does not edit `product.json`
- **AND** the package does not install `/etc/kiro/managed-settings.json`

### Requirement: USE flags and defaults

`IUSE` SHALL include `command-sandbox` enabled by default and `microsoft-auth` disabled by default. `IUSE` SHALL NOT include `test`, `wayland`, `egl`, `kerberos`, `alsa`, `cups`, or a musl flag.

#### Scenario: Default flags are command-sandbox on and microsoft-auth off

- **WHEN** the ebuild `IUSE` is inspected
- **THEN** it contains `+command-sandbox`
- **AND** it contains `microsoft-auth` without a default-on marker
- **AND** it does not contain `test`, `wayland`, `egl`, `kerberos`, `alsa`, `cups`, or a musl flag

### Requirement: Command sandbox dependencies

When `command-sandbox` is enabled, `RDEPEND` SHALL include `sys-apps/bubblewrap` and `net-misc/socat`. When it is disabled, `RDEPEND` SHALL NOT include those atoms.

#### Scenario: Default USE pulls bubblewrap and socat

- **WHEN** the ebuild is emerged with default USE
- **THEN** `RDEPEND` includes `sys-apps/bubblewrap` and `net-misc/socat`

#### Scenario: Disabling the flag drops both atoms

- **WHEN** the ebuild is emerged with `USE=-command-sandbox`
- **THEN** `RDEPEND` does not include `sys-apps/bubblewrap` or `net-misc/socat`

### Requirement: Microsoft authentication extension

When `microsoft-auth` is disabled, the install SHALL omit `/usr/share/kiro/resources/app/extensions/microsoft-authentication`. When it is enabled, that directory SHALL be installed and `RDEPEND` SHALL include `net-libs/webkit-gtk:4.1`, `net-libs/libsoup:3`, `net-misc/curl`, `dev-libs/openssl`, and `sys-apps/util-linux`.

#### Scenario: Default install omits the extension

- **WHEN** the package is installed with default USE
- **THEN** `/usr/share/kiro/resources/app/extensions/microsoft-authentication` is absent
- **AND** `RDEPEND` does not include `net-libs/webkit-gtk`

#### Scenario: Enabling the flag keeps the extension and its libraries

- **WHEN** the package is installed with `USE=microsoft-auth`
- **THEN** `/usr/share/kiro/resources/app/extensions/microsoft-authentication` is present
- **AND** `RDEPEND` includes `net-libs/webkit-gtk:4.1`, `net-libs/libsoup:3`, `net-misc/curl`, `dev-libs/openssl`, and `sys-apps/util-linux`

### Requirement: Renderer sandbox stays unprivileged

The package SHALL install `/usr/share/kiro/chrome-sandbox` with mode `0755`. It SHALL NOT set mode `4755`.

#### Scenario: chrome-sandbox is not setuid

- **WHEN** the package is installed
- **THEN** `/usr/share/kiro/chrome-sandbox` exists with mode `0755`
- **AND** the ebuild does not set mode `4755` on that file

### Requirement: Postinst explains policy and both sandboxes

`pkg_postinst` SHALL elog that `UpdateMode` is `none`, that the command sandbox stays off until the user enables it and is Unavailable without bubblewrap, and that `chrome-sandbox` stays mode `0755` unless the operator sets mode `4755` on a host without user namespaces.

#### Scenario: Elog names the three operator facts

- **WHEN** the ebuild `pkg_postinst` is inspected
- **THEN** it elogs that `UpdateMode` is `none`
- **AND** it elogs that the command sandbox stays off until the user enables it and is Unavailable without bubblewrap
- **AND** it elogs that `chrome-sandbox` stays mode `0755` unless the operator sets mode `4755` on a host without user namespaces

### Requirement: Prebuilt package has no test phase

The ebuild SHALL NOT define `src_test` and SHALL NOT add `test` to `IUSE`. `RESTRICT` SHALL include `bindist`, `mirror`, and `strip`. `QA_PREBUILT` SHALL cover `/usr/share/kiro`.

#### Scenario: No test USE

- **WHEN** the ebuild is inspected
- **THEN** it has no `src_test`
- **AND** `IUSE` does not include `test`
- **AND** `RESTRICT` includes `bindist`, `mirror`, and `strip`
- **AND** `QA_PREBUILT` covers `/usr/share/kiro`

### Requirement: glibc floor and libsecret stay unconditional

`RDEPEND` SHALL include `>=sys-libs/glibc-2.34` and `app-crypt/libsecret` with no USE condition on either atom. It SHALL NOT include `sys-libs/musl`.

#### Scenario: Both atoms survive microsoft-auth off

- **WHEN** the ebuild `RDEPEND` is inspected
- **THEN** `>=sys-libs/glibc-2.34` and `app-crypt/libsecret` are not behind a USE flag
- **AND** `sys-libs/musl` is absent

### Requirement: Upstream metadata points at the IDE

`metadata.xml` SHALL set `bugs-to` to `https://github.com/kirodotdev/Kiro/issues` and a website remote id of `https://kiro.dev/`. It SHALL NOT set a GitHub remote id.

#### Scenario: Issue tracker without a source remote

- **WHEN** `metadata.xml` is inspected
- **THEN** `bugs-to` is `https://github.com/kirodotdev/Kiro/issues`
- **AND** the website remote id is `https://kiro.dev/`
- **AND** no `remote-id` has type `github`
