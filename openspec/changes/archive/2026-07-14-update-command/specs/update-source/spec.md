## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: Level-1 ebuild inference

**Reason**: Update techniques require an explicit hardcoded policy per package; source inference is redundant and can disagree with the intended technique. Sources are fully hardcoded alongside techniques.

**Migration**: Add or update the package entry in the hardcoded policy map with an explicit `UpdateSource`. Delete `Update.Infer` and any resolve path that called inference.
