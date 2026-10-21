# update-apply Specification

## ADDED Requirements

### Requirement: kiro-ide-bin policy entry

The canonical hardcoded policy map SHALL include `dev-util/kiro-ide-bin` with HttpJson URLs `https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json` and `https://prod.download.desktop.kiro.dev/stable/metadata-linux-arm64-stable.json`, version field `currentRelease`, technique `GitMvAndManifest`, and an empty arch allowlist. The package SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image.

#### Scenario: Policy resolution

- **WHEN** policy is resolved for `dev-util/kiro-ide-bin`
- **THEN** the technique is `GitMvAndManifest`
- **AND** the source is HttpJson on those two stable metadata URLs with field `currentRelease`
- **AND** the arch allowlist is empty

#### Scenario: Target does not select a version

- **WHEN** `outdated` or `update` selects `dev-util/kiro-ide-bin`, or the unambiguous bare name `kiro-ide-bin`
- **THEN** both tokens resolve to the same inventory key
- **AND** the remote PV comes from `currentRelease` when both documents agree
- **AND** the commands do not interpret a supplied version as a CLI version pin

#### Scenario: Not an image or wait-edge provider

- **WHEN** policy is resolved for `dev-util/kiro-ide-bin`
- **THEN** the package is not an overlay wait-edge provider and is not emerged by the materialize image

### Requirement: Kiro IDE GitMv preserves the ebuild body

A `GitMvAndManifest` apply for `dev-util/kiro-ide-bin` SHALL rename the newest ebuild to the remote PV and SHALL NOT rewrite the ebuild body. The `SRC_URI` filename templates, `IUSE`, the policy file, and the `/usr/share/kiro` install layout SHALL be unchanged aside from `${PV}` expansion at build time.

#### Scenario: Bump from 1.4.5 keeps the tarball templates

- **WHEN** apply bumps `kiro-ide-bin` from `1.4.5` to `1.4.10`
- **THEN** the new ebuild is `kiro-ide-bin-1.4.10.ebuild`
- **AND** `kiro-ide-bin-1.4.5.ebuild` is not left as a second live ebuild
- **AND** the body still contains `kiro-ide-${PV}-stable-linux-x64.tar.gz` and `kiro-ide-${PV}-stable-linux-arm64.tar.gz`
- **AND** `IUSE` still enables `command-sandbox` by default and lists `microsoft-auth`
- **AND** the body still installs `/usr/share/kiro` and `/etc/kiro/policy.json`
