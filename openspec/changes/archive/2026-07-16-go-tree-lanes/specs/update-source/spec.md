## ADDED Requirements

### Requirement: List comparable GitHub versions

For a GitHub update source, the library SHALL be able to list comparable package versions by retrieving repository tags and/or releases (with pagination as needed), stripping the configured tag prefix, parsing ebuild-style numeric versions, and returning the set of comparable versions ordered by PV comparison. This list capability SHALL be available to the Go tree-lane planner in addition to the existing single “latest” fetch. Non-comparable or empty-after-strip tags SHALL be omitted. Optional `GITHUB_TOKEN` MAY authenticate requests as for latest fetch.

#### Scenario: Multiple versions returned

- **WHEN** a GitHub repository has tags `v0.80.0`, `v0.82.0`, and `v0.84.0` with prefix `v`
- **THEN** the version list includes numeric PVs `0.80.0`, `0.82.0`, and `0.84.0`

#### Scenario: Prefix strip on list

- **WHEN** tags use prefix `bun-v` and a tag is `bun-v1.2.3`
- **THEN** the listed version parses as PV `1.2.3`

## MODIFIED Requirements

### Requirement: Fetch latest upstream version

The library SHALL fetch a latest version for a resolved source:

- GitHub: prefer `releases/latest` tag name; if unavailable, fall back to repository tags and select the maximum version after prefix strip using ebuild version ordering
- npm: registry latest metadata version
- Http: response body stripped of surrounding whitespace

Optional `GITHUB_TOKEN` from the environment MAY authenticate GitHub API requests. Fetch failures SHALL be reported per package without aborting other packages. For Go tree-lane planning, the library SHALL additionally support listing multiple comparable GitHub versions as specified in the list-comparable requirement; non-Go latest-only flows MAY continue to use only the single latest fetch.

#### Scenario: GitHub releases latest

- **WHEN** fetching a GitHub source whose repository has a latest release tag `v2.1.10` and prefix `v`
- **THEN** the resulting version parses as PV `2.1.10`

#### Scenario: npm latest

- **WHEN** fetching Npm source `@fission-ai/openspec` and the registry latest version is `1.5.0`
- **THEN** the resulting version parses as PV `1.5.0`

#### Scenario: Http primary success

- **WHEN** the Http primary URL returns body `0.2.93`
- **THEN** the resulting version parses as PV `0.2.93` without calling the fallback

#### Scenario: Per-package fetch error

- **WHEN** fetch for one package fails with an HTTP error
- **THEN** that package is reported as an error outcome and other packages continue to be checked
