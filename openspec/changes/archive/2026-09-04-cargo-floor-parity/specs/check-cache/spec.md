## ADDED Requirements

### Requirement: Cargo deps plans cache selected direct floor snapshots

A successful cached `DepsAndAssets Cargo` runtime-lane plan SHALL retain the selected normalized direct tag floor or explicit direct-floor absence for every planned Cargo PV. A valid cache hit SHALL provide those snapshots to content assessment, materialize-image floor planning, reuse/full classification, and apply without another tagged Cargo.toml fetch. Donor floors SHALL NOT be cached as tag facts because they belong to current overlay state.

Newly stored Cargo plans SHALL include the snapshots inside the existing deps plan payload. A pre-change Cargo deps entry that lacks the required selected-PV snapshots SHALL be treated as a cache miss and replaced by live planning; a missing Cargo snapshot SHALL NOT be interpreted as a successfully probed absent floor. Existing non-Cargo deps entries SHALL remain usable when otherwise valid.

Cargo deps-plan validity SHALL include the configured tag prefix, Cargo package subdirectory, Cargo lock subdirectory, and floor-policy/parser version in addition to existing source and local-state fingerprint inputs. Changing any of those inputs SHALL make a cached Cargo plan a miss.

#### Scenario: Valid Cargo deps hit does not re-probe tag metadata

- **WHEN** a valid Cargo deps cache entry includes selected direct-floor snapshots for its planned PVs
- **THEN** `outdated` or `update` uses those snapshots for assessment and apply without another tagged Cargo.toml fetch

#### Scenario: Old Cargo plan without snapshots misses

- **WHEN** an otherwise fresh pre-change Cargo deps entry lacks selected direct-floor snapshots
- **THEN** the program treats it as a miss, performs live planning, and does not treat the missing field as an absent Rust declaration

#### Scenario: Existing non-Cargo plan remains compatible

- **WHEN** an otherwise valid Go, Npm, Bun, or Sbcl deps entry has no Cargo floor snapshot field
- **THEN** it remains eligible for a cache hit

#### Scenario: Cargo probe policy change invalidates snapshot

- **WHEN** a cached Cargo plan was produced with a different tag prefix, package subdirectory, lock subdirectory, or floor-policy/parser version
- **THEN** the program treats the entry as a miss
