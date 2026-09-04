## ADDED Requirements

### Requirement: Cargo incomplete tag coverage is not a parseable requirement

For `DepsAndAssets Cargo`, a candidate whose tag-floor discovery is incomplete as specified by `cargo-crates-assets` SHALL NOT be a parseable runtime requirement. Lane selection SHALL skip that candidate the same way it skips an unparseable `go.mod`, and SHALL NOT substitute `"0.0.0"` for incompleteness. A later complete candidate MAY still fill the lane. Complete discovery with no declared rust-version MAY still use the selection-only `"0.0.0"` fallback. Operational fetch or parse failure SHALL still fail planning rather than skip the candidate.

#### Scenario: Incomplete newest candidate is skipped

- **WHEN** the newest Cargo candidate is incomplete because an in-tree path dependency Cargo.toml is missing, and an older candidate completes with tag floor `1.85.0` under the lane ceiling
- **THEN** that lane may select the older candidate and SHALL NOT select the incomplete newest PV as requirement `0.0.0`

#### Scenario: Complete absence still uses the zero fallback

- **WHEN** a Cargo candidate’s active local set is fully resolved and no package declares rust-version
- **THEN** lane selection MAY use `0.0.0` for that candidate
