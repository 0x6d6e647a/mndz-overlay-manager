# net-analyzer-caddy-analyzer-seed Delta

## Purpose

Define the caddy-analyzer overlay donor's build, assets, and offline-test contracts so manager updates retain a working CLI package.

## ADDED Requirements

### Requirement: Seed identity and supported architectures

The seed SHALL be `net-analyzer/caddy-analyzer` at PV `0.7.4`, sourced from GitHub `lenny-ts/caddy-analyzer` tag `v0.7.4`, with `SLOT="0"` and tilde keywords `~amd64 ~arm ~arm64`. Package name `caddy-analyzer` and installed executable name `caddy-analyze` SHALL remain distinct. The seed SHALL include Manifest, metadata.xml, and package md5-cache entries.

#### Scenario: Seed inventory and executable

- **WHEN** the seed is installed
- **THEN** `/usr/bin/caddy-analyze --version` reports `0.7.4`
- **AND** the manager inventory key is `net-analyzer/caddy-analyzer`

### Requirement: Build and install contract

The ebuild SHALL inherit `go-module` and `shell-completion`, build `./cmd/caddy-analyze` with `CGO_ENABLED=0`, and inject `${PV}` into `github.com/lenny-ts/caddy-analyzer/cmd.Version`. The seed's Go BDEPEND SHALL match `go 1.25.13`; updates SHALL obtain the requirement from the target tag. The ebuild SHALL retain Bash, Fish, and Zsh completion USE flags and failure-checked generation via `caddy-analyze completion`. Its LICENSE SHALL cover the seed's statically linked dependencies (`Apache-2.0 BSD ISC MIT`).

#### Scenario: Completion generation does not consume access logs

- **WHEN** a shell-completion USE flag is enabled during install
- **THEN** the corresponding completion script is generated without an access log or GeoIP download
- **AND** failed generation prevents installation of that script

### Requirement: Asset origin and offline module cache

The donor SHALL use the configured assets repository for release `caddy-analyzer-${PV}` and asset `caddy-analyzer-${PV}-vendor.tar.xz`, with a top-level `go-mod/` module cache. Before manager acceptance, the seed vendor URL and the `assets-path` origin SHALL agree, and required checksum sidecars SHALL be present or reconciled using the existing assets conventions. A fork-hosted seed release SHALL NOT be treated as proof that the corresponding upstream assets release exists.

#### Scenario: Seed remains in the assets fork

- **WHEN** the seed vendor archive remains in `airencracken/mndz-overlay-assets`
- **THEN** acceptance uses an assets checkout with that repository as its origin
- **AND** the donor vendor URL names that same repository

#### Scenario: Seed is mirrored to the upstream assets repository

- **WHEN** the operator chooses `0x6d6e647a/mndz-overlay-assets` as the assets origin
- **THEN** the seed archive and sidecars are verified in that repository before the donor URL is changed
- **AND** the Manifest digests match the published bytes

### Requirement: Local patch reference survives version changes

While the GeoIP fix is needed, the donor SHALL refer explicitly to `${FILESDIR}/caddy-analyzer-0.7.4-offline-geoip.patch`, rather than constructing that filename from the updated `${P}`. Patch removal or replacement SHALL require verification against the target upstream source and an explicit overlay edit. Content-only corrections to a published seed SHALL increase its Portage revision.

#### Scenario: A newer PV retains an existing patch file

- **WHEN** a manager update writes an ebuild for a newer PV from the prepared donor
- **THEN** its patch reference still resolves to the retained `caddy-analyzer-0.7.4-offline-geoip.patch` file
- **AND** update does not invent a patch filename for the newer PV

### Requirement: Offline tests and bounded operator smoke

The seed SHALL include `IUSE=test`, `RESTRICT="!test? ( test )"`, and `src_test` running the Go suite with temporary configuration and no external GeoIP downloads. Smoke validation SHALL exercise version, help, completion, and analysis of synthetic logs with `--no-auto-download`. Acceptance SHALL NOT run the self-update command or change firewall rules; optional firewall dependency notices SHALL remain in the ebuild.

#### Scenario: Analyze synthetic logs without GeoIP data

- **WHEN** a synthetic Caddy access log is analyzed with `--no-auto-download -f json`
- **THEN** output is valid JSON with the expected request count
- **AND** missing GeoIP data does not crash interval reporting

#### Scenario: Test USE flag disabled

- **WHEN** `USE=-test` and `FEATURES=test` would otherwise enable tests
- **THEN** Portage restricts the package test phase
