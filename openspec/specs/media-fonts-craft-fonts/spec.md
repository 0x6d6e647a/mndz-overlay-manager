# media-fonts-craft-fonts Specification

## Purpose

Product truth for `media-fonts/craft-fonts`: the shared OFL checkout Storytold craft apps embed at build time, and the pre-tag snapshot the manager refuses to bump.

## Requirements

### Requirement: Snapshot package identity

The overlay package SHALL be `media-fonts/craft-fonts` at PV `0.0.0`. Its `SRC_URI` SHALL fetch a commit archive of GitHub `storytold/craft-fonts`. It SHALL NOT fetch a tag archive or a crates.io crate.

#### Scenario: Pre-tag filename and source

- **WHEN** the font package is added
- **THEN** the ebuild path is `media-fonts/craft-fonts/craft-fonts-0.0.0.ebuild`
- **AND** `SRC_URI` downloads `https://github.com/storytold/craft-fonts/archive/<commit>.tar.gz` for the packed commit
- **AND** no `SRC_URI` entry uses `refs/tags/` or a crates tarball

### Requirement: Checkout install layout

The ebuild SHALL install `fonts/manifest.txt` and the family directories under `/usr/share/craft-fonts/fonts/`. It SHALL NOT install the repository's Rust crate. It SHALL NOT register the fonts with fontconfig.

#### Scenario: Build scripts see the checkout root

- **WHEN** the package is installed
- **THEN** `/usr/share/craft-fonts/fonts/manifest.txt` exists
- **AND** each family directory named by that manifest is installed beside it
- **AND** no fontconfig configuration file is installed

### Requirement: License and subslot

`LICENSE` SHALL be `OFL-1.1`. `SLOT` SHALL be `0/${PV}`.

#### Scenario: Slot moves with the snapshot

- **WHEN** the ebuild is inspected
- **THEN** `LICENSE` is `OFL-1.1`
- **AND** `SLOT` is `0/${PV}`

### Requirement: Keywords

The ebuild SHALL set `KEYWORDS="-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390"`.

#### Scenario: Keyword string

- **WHEN** the ebuild is inspected
- **THEN** `KEYWORDS` is `-* ~amd64 ~x86 ~arm ~arm64 ~ppc64 ~loong ~riscv ~sparc ~s390`

### Requirement: Unsupported while tags are absent

Policy for `media-fonts/craft-fonts` SHALL use technique `Unsupported` with a reason that `storytold/craft-fonts` publishes no comparable numeric tag. `update` SHALL soft-skip the package and include that reason. `outdated` SHALL NOT report a newer version for it.

#### Scenario: update soft-skips

- **WHEN** `update` selects `media-fonts/craft-fonts` or the unambiguous bare name `craft-fonts`
- **THEN** the package is soft-skipped
- **AND** the skip reason names the unsupported technique
- **AND** the ebuild filename stays `craft-fonts-0.0.0.ebuild`

#### Scenario: outdated does not invent a bump

- **WHEN** `outdated` selects `media-fonts/craft-fonts` while the technique is `Unsupported`
- **THEN** it does not report a newer version for that package

### Requirement: No crates asset

The package SHALL NOT publish a crates release and SHALL NOT reference `mndz-overlay-assets`.

#### Scenario: Assets repository is unused

- **WHEN** the font ebuild and its policy entry are inspected
- **THEN** no `SRC_URI` entry points at `mndz-overlay-assets`
- **AND** the technique does not require an assets publish
