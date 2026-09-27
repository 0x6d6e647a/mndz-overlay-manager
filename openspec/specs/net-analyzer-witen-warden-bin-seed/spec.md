# net-analyzer-witen-warden-bin-seed Specification

## Purpose

Seeded overlay package truth for `net-analyzer/witen-warden-bin`: the prebuilt Witen Warden jailer, its version-templated Linux distfiles, and the install layout left after the 0.1.19 bump.

## Requirements

### Requirement: Warden package identity

The overlay SHALL ship `net-analyzer/witen-warden-bin` as a prebuilt package. The live ebuild SHALL be `witen-warden-bin-0.1.19.ebuild`. `KEYWORDS` SHALL be `-* ~amd64`. `LICENSE` SHALL be `all-rights-reserved`. The homepage SHALL be `https://www.witenlabs.com`.

#### Scenario: Live ebuild is 0.1.19 for amd64

- **WHEN** the live `net-analyzer/witen-warden-bin` ebuild is inspected
- **THEN** its filename PV is `0.1.19`
- **AND** `KEYWORDS` is `-* ~amd64`
- **AND** `LICENSE` is `all-rights-reserved`
- **AND** the homepage is `https://www.witenlabs.com`

### Requirement: Version-templated distfiles

`SRC_URI` SHALL download both of the following for the ebuild PV:

- `https://www.witenlabs.com/api/releases/warden/artifacts/witen-warden-${PV}-linux-amd64-glibc.tar.gz`
- `https://www.witenlabs.com/api/releases/warden/artifacts/witen-warden_${PV}-1_amd64.deb`

The Debian artifact revision in that URL SHALL stay `-1`. A later `GitMvAndManifest` bump SHALL change only the filename PV and SHALL preserve both URL shapes.

#### Scenario: Both artifacts follow PV

- **WHEN** the ebuild `SRC_URI` is inspected
- **THEN** it contains `witen-warden-${PV}-linux-amd64-glibc.tar.gz`
- **AND** it contains `witen-warden_${PV}-1_amd64.deb`

### Requirement: Install layout

`src_install` SHALL install the upstream binary at `/usr/bin/warden`. It SHALL install the systemd unit `witen-warden.service` and the helper scripts `prepare-state`, `prepare-log-access`, and `smoke-journal` under `/usr/libexec/witen-warden/`. It SHALL install an OpenRC init script and conf.d whose command path is `/usr/bin/warden`. It SHALL install `/etc/witen/warden.toml`, the logrotate policy, bash completion, and the upstream man pages. The package SHALL create the `witen-warden` user and group, with home `/var/lib/witen` and shell nologin. The package SHALL NOT run the portable `install.sh` and SHALL NOT run Debian maintainer scripts. Installing or upgrading the package SHALL NOT enable the service and SHALL NOT start or restart it.

#### Scenario: Command and service names

- **WHEN** the package is installed
- **THEN** `/usr/bin/warden` exists and is executable
- **AND** the OpenRC init script and conf.d name `/usr/bin/warden` as the command
- **AND** the systemd unit's `ExecStart` names `/usr/bin/warden`
- **AND** user and group `witen-warden` exist
- **AND** the `witen-warden` service is not enabled and is not running solely because the package was installed or upgraded

#### Scenario: Configuration is installed once

- **WHEN** the package is installed and `/etc/witen/warden.toml` was absent
- **THEN** `/etc/witen/warden.toml` is installed from the upstream default
- **AND** its mode is `0640` and its group is `witen-warden`

### Requirement: Dependencies and USE flags

The ebuild SHALL RDEPEND on nftables, ca-certificates, acl, and `virtual/logger`. `IUSE` SHALL include `iptables`, disabled by default, and enabling it SHALL add an iptables dependency. `IUSE` SHALL NOT include `test`.

#### Scenario: Default dependencies

- **WHEN** the ebuild is inspected with default USE
- **THEN** nftables, ca-certificates, acl, and `virtual/logger` are dependencies
- **AND** `iptables` is not enabled by default
- **AND** `IUSE` does not include `test`

### Requirement: Prebuilt package has no test phase

The ebuild SHALL NOT define `src_test`. `RESTRICT` SHALL include `bindist`, `mirror`, and `strip`. `QA_PREBUILT` SHALL cover `/usr/bin/warden`.

#### Scenario: No test USE

- **WHEN** the ebuild is inspected
- **THEN** it has no `src_test`
- **AND** `RESTRICT` includes `bindist`, `mirror`, and `strip`
- **AND** `QA_PREBUILT` covers `/usr/bin/warden`

### Requirement: Safe version smoke

With the package installed and `witen-warden` not started, `warden --version` SHALL print `warden` followed by the installed PV, and `warden version --json` SHALL report that same version. `warden validate` against the installed config SHALL report `config`, `config_schema`, `actuator`, and `firewall_nft` as ok. The overall validate status MAY be failed while the daemon is stopped. The admin socket, the nftables hook, and the live source check are not required to pass in that state.

#### Scenario: Version matches the installed PV

- **WHEN** `witen-warden-bin-0.1.19` is installed and the service is stopped
- **THEN** `warden --version` prints `warden 0.1.19`
- **AND** `warden version --json` reports version `0.1.19`
- **AND** `warden validate` reports `config`, `config_schema`, `actuator`, and `firewall_nft` as ok
