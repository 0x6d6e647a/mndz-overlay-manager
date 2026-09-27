# Spec Delta

## MODIFIED Requirements

### Requirement: Warden package identity

The overlay SHALL ship `net-analyzer/witen-warden-bin` as a prebuilt package. The live ebuild SHALL be `witen-warden-bin-0.1.19-r1.ebuild`. `KEYWORDS` SHALL be `-* ~amd64`. `LICENSE` SHALL be `all-rights-reserved`. The homepage SHALL be `https://www.witenlabs.com`.

#### Scenario: Live ebuild is 0.1.19 for amd64

- **WHEN** the live `net-analyzer/witen-warden-bin` ebuild is inspected
- **THEN** its filename is `witen-warden-bin-0.1.19-r1.ebuild`
- **AND** its filename PV is `0.1.19`
- **AND** `KEYWORDS` is `-* ~amd64`
- **AND** `LICENSE` is `all-rights-reserved`
- **AND** the homepage is `https://www.witenlabs.com`

### Requirement: Install layout

`src_install` SHALL install the upstream binary at `/usr/bin/warden`. It SHALL install the systemd unit `witen-warden.service` and the helper scripts `prepare-state`, `prepare-log-access`, and `smoke-journal` under `/usr/libexec/witen-warden/`. It SHALL install an OpenRC init script and conf.d whose command path is `/usr/bin/warden`. It SHALL install `/etc/witen/warden.toml`, the logrotate policy, and the upstream man pages. When `bash-completion` is enabled, it SHALL install the upstream bash completion file at `/usr/share/bash-completion/completions/warden`. When `bash-completion` is disabled, that file SHALL NOT be installed. The package SHALL create the `witen-warden` user and group, with home `/var/lib/witen` and shell nologin. The package SHALL NOT run the portable `install.sh` and SHALL NOT run Debian maintainer scripts. Installing or upgrading the package SHALL NOT enable the service and SHALL NOT start or restart it.

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

#### Scenario: Bash completion is installed when enabled

- **WHEN** the package is installed with `bash-completion` enabled
- **THEN** `/usr/share/bash-completion/completions/warden` is installed
- **AND** the systemd unit, the OpenRC init script, and the logrotate policy are still installed

#### Scenario: Bash completion is omitted when disabled

- **WHEN** the package is installed with `bash-completion` disabled
- **THEN** `/usr/share/bash-completion/completions/warden` is not installed
- **AND** the systemd unit, the OpenRC init script, and the logrotate policy are still installed

### Requirement: Dependencies and USE flags

The ebuild SHALL RDEPEND on nftables, ca-certificates, acl, and `virtual/logger`. `IUSE` SHALL include `iptables`, disabled by default, and enabling it SHALL add an iptables dependency. `IUSE` SHALL include `bash-completion`, disabled by default, and enabling it SHALL add a dependency on `app-shells/bash-completion`. With `bash-completion` disabled, `app-shells/bash-completion` SHALL NOT be a dependency. `IUSE` SHALL NOT include `test`.

#### Scenario: Default dependencies

- **WHEN** the ebuild is inspected with default USE
- **THEN** nftables, ca-certificates, acl, and `virtual/logger` are dependencies
- **AND** `iptables` is not enabled by default
- **AND** `bash-completion` is not enabled by default
- **AND** `IUSE` does not include `test`

#### Scenario: bash-completion enabled adds its dependency

- **WHEN** the ebuild is inspected with `bash-completion` enabled
- **THEN** `app-shells/bash-completion` is a dependency

#### Scenario: bash-completion disabled omits its dependency

- **WHEN** the ebuild is inspected with `bash-completion` disabled
- **THEN** `app-shells/bash-completion` is not a dependency
