## MODIFIED Requirements

### Requirement: Cargo deps plans cache selected direct floor snapshots

A successful cached `DepsAndAssets Cargo` runtime-lane plan SHALL retain, for every planned Cargo PV, the selected normalized tag floor or explicit tag-floor absence, coverage (`Complete` or `Incomplete` with reasons), resolved-path provenance, and the floor-policy/parser version that produced them. A valid cache hit SHALL provide those snapshots to content assessment, materialize-image floor planning, reuse/full classification, and apply without another tagged Cargo.toml fetch. Donor floors SHALL NOT be cached as tag facts because they belong to current overlay state. Facts about candidates that were probed but not selected SHALL NOT be required in the persisted payload.

Newly stored Cargo plans SHALL include those snapshots inside the existing deps plan payload. A Cargo deps entry that lacks the required selected-PV snapshots, coverage, or current floor-policy version SHALL be treated as a cache miss and replaced by live planning; a missing Cargo snapshot SHALL NOT be interpreted as a successfully probed absent floor. Existing non-Cargo deps entries SHALL remain usable when otherwise valid.

Cargo deps-plan validity SHALL include the configured tag prefix, Cargo package subdirectory, Cargo lock subdirectory, and floor-policy/parser version in addition to existing source and local-state fingerprint inputs. Changing any of those inputs SHALL make a cached Cargo plan a miss.

#### Scenario: Valid Cargo deps hit does not re-probe tag metadata

- **WHEN** a valid Cargo deps cache entry includes selected tag-floor snapshots with coverage and provenance for its planned PVs under the current floor-policy version
- **THEN** `outdated` or `update` uses those snapshots for assessment and apply without another tagged Cargo.toml fetch

#### Scenario: Old Cargo plan without snapshots misses

- **WHEN** an otherwise fresh pre-change Cargo deps entry lacks selected tag-floor snapshots
- **THEN** the program treats it as a miss, performs live planning, and does not treat the missing field as an absent Rust declaration

#### Scenario: Prior floor-policy version misses

- **WHEN** a cached Cargo plan was stored under a previous floor-policy/parser version
- **THEN** the program treats the entry as a miss and replaces it after a successful live plan

#### Scenario: Existing non-Cargo plan remains compatible

- **WHEN** an otherwise valid Go, Npm, Bun, or Sbcl deps entry has no Cargo floor snapshot field
- **THEN** it remains eligible for a cache hit

#### Scenario: Cargo probe policy change invalidates snapshot

- **WHEN** a cached Cargo plan was produced with a different tag prefix, package subdirectory, lock subdirectory, or floor-policy/parser version
- **THEN** the program treats the entry as a miss
