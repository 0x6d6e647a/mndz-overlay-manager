# update-source Delta

## MODIFIED Requirements

### Requirement: Hardcoded source overrides

The library SHALL provide a hardcoded map from package key `category/package` to update source as part of each package’s policy entry. Resolution of an update source SHALL use only this hardcoded map. At minimum, `dev-util/grok-build-bin` SHALL map to an Http source for the grok-build stable channel (primary `https://x.ai/cli/stable` with the known GCS fallback). `dev-util/grok-bot-bin` SHALL map to the Cursor stable download feeds `https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand` and `https://api2.cursor.sh/updates/api/download/stable/linux-arm64/sand`, each an HttpJson source whose version field is `version`. `net-analyzer/witen-warden-bin` SHALL map to an Http source whose primary URL is `https://www.witenlabs.com/api/releases/warden/version` and which has no fallback URL. `net-analyzer/caddy-analyzer` SHALL map to GitHub owner `lenny-ts`, repository `caddy-analyzer`, with tag prefix `v`. `media-gfx/photocraft` SHALL map to GitHub owner `storytold`, repository `photocraft`, with tag prefix `v`. The map SHALL also include explicit sources for all other packages known in the mndz overlay policy set (GitHub, npm, Http, or HttpJson as appropriate).

#### Scenario: Grok-build uses hardcoded Http

- **WHEN** resolving an update source for `dev-util/grok-build-bin`
- **THEN** the hardcoded Http stable-channel source is used

#### Scenario: Grok Bot uses the stable download feeds

- **WHEN** resolving an update source for `dev-util/grok-bot-bin`
- **THEN** the linux-x64 and linux-arm64 stable download feeds are used
- **AND** each feed's version is the JSON field `version`

#### Scenario: Warden uses the version feed

- **WHEN** resolving an update source for `net-analyzer/witen-warden-bin`
- **THEN** the Http source primary URL is `https://www.witenlabs.com/api/releases/warden/version`
- **AND** that source has no fallback URL

#### Scenario: Mapped GitHub package

- **WHEN** resolving an update source for a package whose policy specifies a GitHub source
- **THEN** that GitHub source is returned without reading ebuild text for inference

#### Scenario: Unmapped package has no source

- **WHEN** resolving an update source for a package key absent from the hardcoded map
- **THEN** resolve reports no source for that package

#### Scenario: Caddy analyzer uses the canonical GitHub repository

- **WHEN** resolving an update source for `net-analyzer/caddy-analyzer`
- **THEN** the source is GitHub `lenny-ts/caddy-analyzer` with tag prefix `v`
- **AND** release tag `v0.7.4` parses as PV `0.7.4` using the existing GitHub fetch rules
- **AND** no update source is inferred from the ebuild or the installed binary

#### Scenario: Photocraft uses the storytold GitHub repository

- **WHEN** resolving an update source for `media-gfx/photocraft`
- **THEN** the source is GitHub `storytold/photocraft` with tag prefix `v`
- **AND** release tag `v0.1.1` parses as PV `0.1.1` using the existing GitHub fetch rules
- **AND** a tag that does not parse as a numeric PV is not a comparable version
- **AND** no update source is inferred from the ebuild
