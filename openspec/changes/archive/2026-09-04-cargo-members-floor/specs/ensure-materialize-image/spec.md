## ADDED Requirements

### Requirement: Cargo rust image floor uses the planned tag snapshot

When ensure computes this prepare’s Rust floor from a classified full-path `DepsAndAssets Cargo` unit, it SHALL use that PV’s planned tag-floor snapshot from `cargo-crates-assets`. An explicit complete tag-floor absence SHALL NOT contribute a rust floor token of `0.0.0`. Incomplete tag coverage SHALL NOT reach ensure as a selected full-path unit. Donor, template, and post-fetch harvest floors SHALL NOT replace the planned tag snapshot for image-floor planning.

#### Scenario: Declared tag floor feeds ensure

- **WHEN** a full-path Cargo unit’s planned tag floor is `1.91.0`
- **THEN** this prepare’s Rust floor is at least `1.91.0`

#### Scenario: Selection fallback does not become an image floor

- **WHEN** a full-path Cargo unit’s tag snapshot is explicit absence and candidate selection used `0.0.0`
- **THEN** ensure does not treat `0.0.0` as a required Rust image floor for that unit
