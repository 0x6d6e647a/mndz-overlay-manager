## ADDED Requirements

### Requirement: Update source model

The library SHALL model an update source as one of: GitHub (owner, repository, tag prefix), npm (registry package name), or Http (primary URL and optional fallback URL returning a plain-text version body).

#### Scenario: GitHub source fields

- **WHEN** a GitHub update source is constructed for `anomalyco/opencode` with prefix `v`
- **THEN** fetch logic can request that repository's latest release tag and strip the prefix `v` before version parse

#### Scenario: Http source with fallback

- **WHEN** an Http update source has a primary URL and a fallback URL
- **THEN** fetch tries the primary first and uses the fallback only if the primary does not yield a usable version body

### Requirement: Hardcoded source overrides

The library SHALL provide a hardcoded map from package key `category/package` to update source. Hardcoded entries SHALL take precedence over ebuild inference. At minimum, `dev-util/grok-build-bin` SHALL map to an Http source for the grok-build stable channel (primary `https://x.ai/cli/stable` with the known GCS fallback).

#### Scenario: Grok-build uses hardcoded Http

- **WHEN** resolving an update source for `dev-util/grok-build-bin`
- **THEN** the hardcoded Http stable-channel source is used without requiring successful ebuild inference

### Requirement: Level-1 ebuild inference

When no hardcoded source exists for a package, the library SHALL attempt to infer an update source by reading the newest local ebuild file text, applying a narrow expander for simple assignments and `${PN}`, `${PV}`, `${P}`, `${PN//-bin/}`, and `${VAR}` references in URL-like strings, then matching:

1. npm registry URLs → Npm source  
2. else GitHub tag-archive or release-download URLs (excluding `github.com/0x6d6e647a/mndz-overlay-assets`) → GitHub source with owner, repo, and tag prefix derived from the path segment containing PV  
3. else no source  

HOMEPAGE alone SHALL NOT establish a source when it conflicts with a stronger SRC_URI signal; npm matches SHALL take priority over GitHub.

#### Scenario: Infer GitHub tag archive

- **WHEN** ebuild text contains `https://github.com/dolthub/dolt/archive/refs/tags/v${PV}.tar.gz` and no npm URL
- **THEN** inference yields GitHub owner `dolthub`, repo `dolt`, prefix `v`

#### Scenario: Infer GitHub release with variable expansion

- **WHEN** package name is `bun-bin` and ebuild text assigns `BUN_PN="${PN//-bin/}"` and uses `https://github.com/oven-sh/${BUN_PN}/releases/download/${BUN_PN}-v${PV}`
- **THEN** inference yields GitHub owner `oven-sh`, repo `bun`, prefix `bun-v`

#### Scenario: Infer npm over GitHub homepage

- **WHEN** ebuild text contains both an npm registry URL for `@fission-ai/openspec` and a GitHub HOMEPAGE
- **THEN** inference yields Npm package `@fission-ai/openspec`

#### Scenario: Ignore overlay assets URLs

- **WHEN** the only GitHub URLs in the ebuild point at `0x6d6e647a/mndz-overlay-assets`
- **THEN** inference does not treat the assets repository as the upstream source

#### Scenario: Inference failure

- **WHEN** no hardcoded source exists and inference finds no usable npm or GitHub pattern
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
