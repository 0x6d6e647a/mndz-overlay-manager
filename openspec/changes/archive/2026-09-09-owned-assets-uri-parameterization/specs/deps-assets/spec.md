## MODIFIED Requirements

### Requirement: Uniform planned adequacy and path evaluation

For a planned `DepsAndAssets` PV, the program SHALL use one content-assessment rule over the plan's selected upstream requirement snapshot and one canonical local ebuild. The assessment SHALL cover ebuild presence, parameterized asset SRC_URI content, planned KEYWORDS, the ecosystem runtime field, and exact Manifest `DIST` filename presence for every required primary and companion distfile. Given the same plan snapshot and overlay state, `outdated`, update planning, and the direct plan-and-apply entry SHALL produce the same needs-work result. Production apply SHALL consume the update plan's content result without independently reclassifying it; for Cargo it SHALL also consume the selected tag-floor snapshot without another tagged Cargo.toml fetch. This requirement does not prohibit existing write-time requirement fetches for other ecosystems.

Parameterized asset SRC_URI SHALL mean package-owned mndz-overlay-assets release download URLs only. A release tag after `mndz-overlay-assets/releases/download/` is package-owned when it contains `${PV}` or starts with `{pn}-`. Those tags, and filenames under them that start with `{pn}-`, SHALL use `${PV}` (not a frozen overlay package version). Assets-host tags that are not package-owned are a different version axis: they SHALL NOT be rewritten to `{pn}-${PV}`, and their lack of `${PV}` SHALL NOT by itself make the PV need work. Non-assets `SRC_URI` entries (no mndz-overlay-assets download marker) remain out of this check. Write and check SHALL use the same ownership test.

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

#### Scenario: Pin-keyed assets URL is not a package-PV content fix

- **WHEN** a present planned PV's canonical ebuild has a parameterized `{pn}-${PV}` crates (or vendor/deps) assets URL and a second mndz-overlay-assets URL whose release tag is `rusty-v8-${RUSTY_V8_VER}` (no `${PV}`)
- **THEN** that second URL does not by itself make the PV need work

#### Scenario: Frozen package-owned assets URL still needs work

- **WHEN** a present planned PV's canonical ebuild has `…/mndz-overlay-assets/releases/download/{pn}-1.2.3/{pn}-1.2.3-crates.tar.xz` (or vendor/deps equivalent) with no `${PV}`
- **THEN** the PV needs work for asset URI parameterization
