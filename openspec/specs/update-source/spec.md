# update-source Specification

## Purpose

TBD

## Requirements

### Requirement: Update source model

The library SHALL model an update source as one of: GitHub (owner, repository, tag prefix), npm (registry package name), or Http (primary URL and optional fallback URL returning a plain-text version body).

#### Scenario: GitHub source fields

- **WHEN** a GitHub update source is constructed for `anomalyco/opencode` with prefix `v`
- **THEN** fetch logic can request that repository's latest release tag and strip the prefix `v` before version parse

#### Scenario: Http source with fallback

- **WHEN** an Http update source has a primary URL and a fallback URL
- **THEN** fetch tries the primary first and uses the fallback only if the primary does not yield a usable version body

### Requirement: Hardcoded source overrides

The library SHALL provide a hardcoded map from package key `category/package` to update source as part of each package’s policy entry. Resolution of an update source SHALL use only this hardcoded map. At minimum, `dev-util/grok-build-bin` SHALL map to an Http source for the grok-build stable channel (primary `https://x.ai/cli/stable` with the known GCS fallback). The map SHALL also include explicit sources for all other packages known in the mndz overlay policy set (GitHub, npm, or Http as appropriate).

#### Scenario: Grok-build uses hardcoded Http

- **WHEN** resolving an update source for `dev-util/grok-build-bin`
- **THEN** the hardcoded Http stable-channel source is used

#### Scenario: Mapped GitHub package

- **WHEN** resolving an update source for a package whose policy specifies a GitHub source
- **THEN** that GitHub source is returned without reading ebuild text for inference

#### Scenario: Unmapped package has no source

- **WHEN** resolving an update source for a package key absent from the hardcoded map
- **THEN** resolve reports no source for that package

### Requirement: Fetch latest upstream version

The library SHALL fetch a latest version for a resolved source:

- GitHub: prefer `releases/latest` tag name; if unavailable, fall back to repository tags and select the maximum version after prefix strip using ebuild version ordering  
- npm: registry latest metadata version  
- Http: response body stripped of surrounding whitespace  

Optional `GITHUB_TOKEN` from the environment MAY authenticate GitHub API requests. Fetch failures SHALL be reported per package without aborting other packages.

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
