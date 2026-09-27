# Spec Delta

## MODIFIED Requirements

### Requirement: Update source model

The library SHALL model an update source as one of: GitHub (owner, repository, tag prefix), npm (registry package name), Http (primary URL and optional fallback URL returning a plain-text version body), or HttpJson (a URL whose body is a JSON object, plus the name of the field that holds the version).

#### Scenario: GitHub source fields

- **WHEN** a GitHub update source is constructed for `anomalyco/opencode` with prefix `v`
- **THEN** fetch logic can request that repository's latest release tag and strip the prefix `v` before version parse

#### Scenario: Http source with fallback

- **WHEN** an Http update source has a primary URL and a fallback URL
- **THEN** fetch tries the primary first and uses the fallback only if the primary does not yield a usable version body

#### Scenario: HttpJson reads the named version field

- **WHEN** an HttpJson source names the field `version` and the document is `{"version":"0.61.0","commitSha":"47a9d1df3a7d37aaa53d206ab2d1f9159a336223"}`
- **THEN** the fetched version parses as PV `0.61.0`
- **AND** the surrounding JSON document is not stored as the version

### Requirement: Hardcoded source overrides

The library SHALL provide a hardcoded map from package key `category/package` to update source as part of each package’s policy entry. Resolution of an update source SHALL use only this hardcoded map. At minimum, `dev-util/grok-build-bin` SHALL map to an Http source for the grok-build stable channel (primary `https://x.ai/cli/stable` with the known GCS fallback). `dev-util/grok-bot-bin` SHALL map to the Cursor stable download feeds `https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand` and `https://api2.cursor.sh/updates/api/download/stable/linux-arm64/sand`, each an HttpJson source whose version field is `version`. The map SHALL also include explicit sources for all other packages known in the mndz overlay policy set (GitHub, npm, Http, or HttpJson as appropriate).

#### Scenario: Grok-build uses hardcoded Http

- **WHEN** resolving an update source for `dev-util/grok-build-bin`
- **THEN** the hardcoded Http stable-channel source is used

#### Scenario: Grok Bot uses the stable download feeds

- **WHEN** resolving an update source for `dev-util/grok-bot-bin`
- **THEN** the linux-x64 and linux-arm64 stable download feeds are used
- **AND** each feed's version is the JSON field `version`

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
- HttpJson: the named field of the JSON object, stripped of surrounding whitespace, parsed as an ebuild version

Optional `GITHUB_TOKEN` from the environment MAY authenticate GitHub API requests. Fetch failures SHALL be reported per package without aborting other packages. For Go tree-lane planning, the library SHALL additionally support listing multiple comparable GitHub versions as specified in the list-comparable requirement; non-Go latest-only flows MAY continue to use only the single latest fetch.

For `dev-util/grok-bot-bin`, the comparable version SHALL be the version from the linux-x64 feed only when the linux-arm64 feed reports the same version. Differing versions SHALL be a fetch error for that package.

#### Scenario: GitHub releases latest

- **WHEN** fetching a GitHub source whose repository has a latest release tag `v2.1.10` and prefix `v`
- **THEN** the resulting version parses as PV `2.1.10`

#### Scenario: npm latest

- **WHEN** fetching Npm source `@fission-ai/openspec` and the registry latest version is `1.5.0`
- **THEN** the resulting version parses as PV `1.5.0`

#### Scenario: Http primary success

- **WHEN** the Http primary URL returns body `0.2.93`
- **THEN** the resulting version parses as PV `0.2.93` without calling the fallback

#### Scenario: HttpJson field is the version

- **WHEN** an HttpJson feed returns `{"version":"0.61.0","commitSha":"abc"}`
- **THEN** the resulting version parses as PV `0.61.0`

#### Scenario: Grok Bot arches disagree

- **WHEN** the linux-x64 feed version is `0.62.0` and the linux-arm64 feed version is `0.61.0`
- **THEN** the `dev-util/grok-bot-bin` fetch is an error
- **AND** no single version is reported for that package

#### Scenario: Per-package fetch error

- **WHEN** fetch for one package fails with an HTTP error
- **THEN** that package is reported as an error outcome and other packages continue to be checked
