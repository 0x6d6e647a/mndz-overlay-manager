# net-analyzer-caddy-analyzer-seed Delta

## Purpose

Define the caddy-analyzer overlay donor's build, assets, and offline-test contracts so manager updates retain a working CLI package.

## ADDED Requirements

### Requirement: Seed identity and supported architectures

The seed SHALL be `net-analyzer/caddy-analyzer` at PV `0.7.4`, sourced from GitHub `lenny-ts/caddy-analyzer` tag `v0.7.4`, with `SLOT="0"` and `KEYWORDS="-* ~amd64 ~arm ~arm64"`. Package name `caddy-analyzer` and installed executable name `caddy-analyze` SHALL remain distinct. The seed SHALL include Manifest, metadata.xml, and package md5-cache entries. The `-*` token is the allowlist mask from `runtime-lanes`; it is not an architecture.

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

The donor vendor URL SHALL be `https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/caddy-analyzer-${PV}/caddy-analyzer-${PV}-vendor.tar.xz`, with a top-level `go-mod/` module cache inside that archive. Before manager acceptance, release `caddy-analyzer-0.7.4`, asset `caddy-analyzer-0.7.4-vendor.tar.xz`, and the required checksum sidecars SHALL exist in `0x6d6e647a/mndz-overlay-assets`, and the Manifest digests SHALL match those published bytes. A copy of the archive on any other GitHub owner SHALL NOT satisfy this requirement. Go apply parameterizes `${PV}` and leaves this owner in place.

#### Scenario: Seed vendor archive is on the production assets repository

- **WHEN** acceptance checks the seed vendor URL
- **THEN** the URL owner and repository are `0x6d6e647a/mndz-overlay-assets`
- **AND** release `caddy-analyzer-0.7.4` contains `caddy-analyzer-0.7.4-vendor.tar.xz` whose bytes match the Manifest

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
