## MODIFIED Requirements

### Requirement: Uniform planned adequacy and path evaluation

For a planned `DepsAndAssets` PV, the program SHALL use one content-assessment rule over the plan's selected upstream requirement snapshot and one canonical local ebuild. The assessment SHALL cover ebuild presence, parameterized asset SRC_URI content, planned KEYWORDS, the ecosystem runtime field, and exact Manifest `DIST` filename presence for every required primary and companion distfile. Given the same plan snapshot and overlay state, `outdated`, update planning, and the direct plan-and-apply entry SHALL produce the same needs-work result. Production apply SHALL consume the update plan's content result without independently reclassifying it; for Cargo it SHALL also consume the selected tag-floor snapshot without another tagged Cargo.toml fetch. This requirement does not prohibit existing write-time requirement fetches for other ecosystems.

The planned assessment SHALL distinguish PVs that need work from PVs that must use full-path materialization. A PV that cannot derive an ecosystem-required reuse write value from its plan snapshot and canonical template SHALL be in both sets. Incomplete Cargo tag-floor coverage SHALL NOT produce a reuse-write floor and SHALL NOT select that PV as a lane target. Release-asset presence SHALL NOT override forced-full status.

A planned PV SHALL be classified as release-asset reuse only when it is not forced full and every required primary and companion basename has a usable release asset. `[assets reusable]` SHALL describe that complete unit-wide condition, not primary-only or partial reuse. An absent release tag SHALL permit full materialization. If a release tag exists but any required asset is missing, or if a complete release exists for a forced-full PV, update SHALL hard-fail that package before mutation because the manager does not update, replace, or delete existing releases.

A Manifest entry SHALL satisfy adequacy only when its first token is exactly `DIST` and its second token is exactly the required basename. Prefixes, suffixes, sidecars, and substring matches SHALL NOT satisfy another basename. Planning SHALL require exact record presence; apply MAY additionally verify sizes and digests and SHALL reject conflicting duplicate exact records rather than select one arbitrarily.

#### Scenario: Plan and outdated agree on content-only need

- **WHEN** a present planned PV's canonical ebuild needs a content fix for asset URI, KEYWORDS, runtime floor, or a required Manifest record
- **THEN** `outdated` and update planning both classify that PV as needing work from the same assessment

#### Scenario: Production apply consumes the plan content decision

- **WHEN** update planning has recorded needs-work and forced-full sets for a package
- **THEN** production apply uses those sets without an independent content classification
- **AND** Cargo apply does not re-fetch its selected tag floor

#### Scenario: Unknown reuse value forces full

- **WHEN** a needs-work PV cannot derive a required reuse write value from its plan snapshot or canonical template and no release tag exists
- **THEN** planning marks the PV forced full and apply takes the full path

#### Scenario: Companion distfile absence is uniform

- **WHEN** a package's Manifest lacks an exact record for a required companion distfile and its canonical ebuild otherwise matches
- **THEN** `outdated`, update planning, and the direct apply assessment all treat the PV as needing work

#### Scenario: Partial existing release hard-fails update

- **WHEN** a package's primary release asset exists but any required companion release asset is missing
- **THEN** the unit is not reusable, update hard-fails that package before mutation, and output does not claim `[assets reusable]`

#### Scenario: Sidecar does not satisfy exact Manifest basename

- **WHEN** Manifest contains `DIST package-1-models.json.asc ...` but the required basename is `package-1-models.json`
- **THEN** the required companion is still considered missing

## ADDED Requirements

### Requirement: Cargo harvest above the selected rust ceiling fails before write

When a full-path `DepsAndAssets Cargo` unit’s clone or registry harvest floor is strictly greater than the rust ceiling of the lane that selected that PV, mutation SHALL hard-fail before overlay ebuild, Manifest, asset publication, or commit. The planned reuse or full route SHALL NOT switch. The error SHALL name the planned tag floor, the harvest floor, the lane ceiling, and the PV.

#### Scenario: Registry harvest exceeds the admitting lane

- **WHEN** a Cargo PV was admitted under rust ceiling `1.92` and extracted-registry harvest is `1.95`
- **THEN** apply hard-fails that unit before overlay writes
- **AND** the error names tag floor, harvest floor, `1.92`, and the PV
