## ADDED Requirements

### Requirement: Uniform planned adequacy and path evaluation

For a planned `DepsAndAssets` PV, the program SHALL use one content-assessment rule over the plan's selected upstream requirement snapshot and one canonical local ebuild. The assessment SHALL cover ebuild presence, parameterized asset SRC_URI content, planned KEYWORDS, the ecosystem runtime field, and exact Manifest `DIST` filename presence for every required primary and companion distfile. Given the same plan snapshot and overlay state, `outdated`, update planning, and the direct plan-and-apply entry SHALL produce the same needs-work result. Production apply SHALL consume the update plan's content result without independently reclassifying it; for Cargo it SHALL also consume the selected direct tag-floor snapshot without another tagged Cargo.toml fetch. This requirement does not prohibit existing write-time requirement fetches for other ecosystems.

The planned assessment SHALL distinguish PVs that need work from PVs that must use full-path materialization. A PV that cannot derive an ecosystem-required reuse write value from its plan snapshot and canonical template SHALL be in both sets. Release-asset presence SHALL NOT override forced-full status.

A planned PV SHALL be classified as release-asset reuse only when it is not forced full and every required primary and companion basename has a usable release asset. `[assets reusable]` SHALL describe that complete unit-wide condition, not primary-only or partial reuse. An absent release tag SHALL permit full materialization. If a release tag exists but any required asset is missing, or if a complete release exists for a forced-full PV, update SHALL hard-fail that package before mutation because the manager does not update, replace, or delete existing releases.

A Manifest entry SHALL satisfy adequacy only when its first token is exactly `DIST` and its second token is exactly the required basename. Prefixes, suffixes, sidecars, and substring matches SHALL NOT satisfy another basename. Planning SHALL require exact record presence; apply MAY additionally verify sizes and digests and SHALL reject conflicting duplicate exact records rather than select one arbitrarily.

#### Scenario: Plan and outdated agree on content-only need

- **WHEN** a present planned PV's canonical ebuild needs a content fix for asset URI, KEYWORDS, runtime floor, or a required Manifest record
- **THEN** `outdated` and update planning both classify that PV as needing work from the same assessment

#### Scenario: Production apply consumes the plan content decision

- **WHEN** update planning has recorded needs-work and forced-full sets for a package
- **THEN** production apply uses those sets without an independent content classification
- **AND** Cargo apply does not re-fetch its selected direct tag floor

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

## MODIFIED Requirements

### Requirement: Shared materialize spine

For each planned PV that needs work under `DepsAndAssets`, update SHALL first classify a per-PV expected route. A PV that is not forced full and has an existing release containing every required primary and companion asset SHALL be `ExpectedReuse`. A PV whose release tag is absent SHALL be `ExpectedFull`. An existing partial release, or any existing release for a forced-full PV, SHALL hard-fail the package because the manager does not mutate a pre-existing release tag.

For an admitted `ExpectedReuse` unit, the program SHALL reuse all required assets, rewrite overlay ebuild content (parameterized assets SRC_URI, planned KEYWORDS, and runtime field from the ecosystem requirement), run `ebuild ... manifest`, verify exact Manifest SHA512 records against downloaded bytes, and create the signed overlay commit for that unit. For an admitted `ExpectedFull` unit, the program SHALL run the ecosystem materializer, publish all required assets before overlay mutation, perform the same overlay/Manifest verification, and commit that unit before the next PV. Host language runtime gates SHALL apply only to full units and Cargo full path SHALL NOT require host rustc.

The classified expected route SHALL survive disk/image admission and be passed into mutation, including plans reclassified after an overlay wait edge. Immediately before each PV unit, the program SHALL revalidate that `ExpectedReuse` still has the complete release and `ExpectedFull` still has no release tag. A mismatch or lookup error SHALL hard-fail instead of switching routes after admission.

When multiple planned PVs need work in one package apply, the program SHALL sequence **missing** PVs before pure **content-fix** units, with stable ascending PV order in each group. Template paths SHALL come from the canonical initial non-live inventory and SHALL be validated before read; an earlier PV write SHALL NOT replace a later unit's planned cross-PV fallback.

#### Scenario: Publish before overlay on full path

- **WHEN** the release tag is absent, the unit was admitted `ExpectedFull`, and materialization succeeds
- **THEN** assets commit, push, and release upload complete before the overlay ebuild for that PV is renamed or rewritten

#### Scenario: Reuse skips rebuild

- **WHEN** release tag `{pn}-{pv}` contains every required asset, the PV is not forced full, and it was admitted `ExpectedReuse`
- **THEN** apply does not rebuild the assets and does not create a new release for that tag

#### Scenario: Missing PV sequenced before content-fix

- **WHEN** the same package needs both a missing planned PV and a content fix on a lower local PV in one update
- **THEN** the missing PV unit runs first but its write does not replace the later unit's initial-inventory template selection

#### Scenario: Existing non-reusable tag hard-fails before admission

- **WHEN** the target tag is partial or the PV is forced full despite an existing complete release
- **THEN** update hard-fails that package before disk/image admission and does not run either materialize route

#### Scenario: Release route change does not switch paths

- **WHEN** release state no longer matches an admitted PV's expected route at the pre-unit recheck
- **THEN** that PV hard-fails rather than switching from reuse to full or full to reuse
