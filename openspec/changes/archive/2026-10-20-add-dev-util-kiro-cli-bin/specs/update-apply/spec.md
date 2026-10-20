# update-apply Specification

## ADDED Requirements

### Requirement: kiro-cli-bin policy entry

The canonical hardcoded policy map SHALL include `dev-util/kiro-cli-bin` with HttpJson URL `https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json`, version field `version`, technique `GitMvAndManifest`, and an empty arch allowlist. The package SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image.

#### Scenario: Policy resolution

- **WHEN** policy is resolved for `dev-util/kiro-cli-bin`
- **THEN** the technique is `GitMvAndManifest`
- **AND** the source is that HttpJson manifest URL with field `version`
- **AND** the arch allowlist is empty

#### Scenario: Target does not select a version

- **WHEN** `outdated` or `update` selects `dev-util/kiro-cli-bin`, or the unambiguous bare name `kiro-cli-bin`
- **THEN** both tokens resolve to the same inventory key
- **AND** the remote PV comes from the manifest `version` field
- **AND** the commands do not interpret a supplied version as a CLI version pin

#### Scenario: Not an image or wait-edge provider

- **WHEN** policy is resolved for `dev-util/kiro-cli-bin`
- **THEN** the package is not an overlay wait-edge provider and is not emerged by the materialize image

### Requirement: Kiro CLI GitMv preserves the ebuild body

A `GitMvAndManifest` apply for `dev-util/kiro-cli-bin` SHALL rename the newest ebuild to the remote PV and SHALL NOT rewrite the ebuild body. The `SRC_URI` filename templates, libc conditionals, dependencies, and the install layout SHALL be unchanged aside from `${PV}` expansion at build time.

#### Scenario: Bump from 2.31.1 keeps the headless filenames

- **WHEN** apply bumps `kiro-cli-bin` from `2.31.1` to `2.32.0`
- **THEN** the new ebuild is `kiro-cli-bin-2.32.0.ebuild`
- **AND** its body still contains `kirocli-x86_64-linux.tar.xz`, `kirocli-aarch64-linux.tar.xz`, `kirocli-x86_64-linux-musl.tar.xz`, and `kirocli-aarch64-linux-musl.tar.xz`
- **AND** the `/usr/bin` install of `kiro-cli`, `kiro-cli-chat`, and `kiro-cli-term` is unchanged
