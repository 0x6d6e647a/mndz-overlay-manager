## MODIFIED Requirements

### Requirement: Per-package newest local version

For each `category/package` with one or more ebuilds, the check SHALL use the newest local version by PV ordering as the local side of the comparison. Source resolution SHALL use the hardcoded package policy only (no ebuild text inference).

#### Scenario: Multiple ebuild versions

- **WHEN** a package directory contains ebuilds for `9.4.5` and `9.6.1`
- **THEN** the local version used for the update check is `9.6.1`

#### Scenario: Source from hardcoded policy

- **WHEN** a package has a hardcoded update source in the policy map
- **THEN** the outdated check uses that source without reading the ebuild for inference

## ADDED Requirements

### Requirement: Unconfigured when absent from policy map

When a package has no hardcoded policy (or no source), the outdated check SHALL treat it as unconfigured and log a warning, continuing with other packages, matching the existing soft-warning behavior for unconfigured packages.

#### Scenario: Package missing from map

- **WHEN** a discovered package is not present in the hardcoded policy map
- **THEN** the program logs a warning that no update source is configured for that package and does not print an outdated stdout line for it
