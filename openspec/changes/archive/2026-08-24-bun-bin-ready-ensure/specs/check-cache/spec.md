## ADDED Requirements

### Requirement: Hypothetical-ceiling deps plans are not stored

When `update` computes a `DepsAndAssets` runtime-lane plan against **hypothetical** overlay ceiling-provider ceilings (provider selected and needs work, as specified by `overlay-apply-waves`), the program SHALL NOT write that plan as a successful check-cache deps payload for that consumer. After the provider’s signed overlay commit, a later successful consumer apply MAY store a deps payload fingerprinted against **on-disk** provider state as already specified. `outdated` SHALL NOT be required to store or hit a hypo-ceiling plan.

#### Scenario: Hypo ralph plan is not cached under pre-bump bun-bin

- **WHEN** `update` plans ralph-tui against bun-bin remote `1.4.0` while overlay bun-bin on disk is `1.3.14` and the check cache is enabled
- **THEN** the program does not store a ralph-tui deps entry whose overlay-provider fingerprint is bun-bin `1.3.14` with a `1.4.0` plan
- **AND** a later run whose bun-bin on-disk fingerprint is still `1.3.14` does not hit that `1.4.0` plan as a valid cache entry

#### Scenario: After bun-bin lands, ralph may cache against disk

- **WHEN** bun-bin has committed `1.4.0` and ralph-tui later applies successfully with the cache enabled
- **THEN** a ralph-tui deps entry MAY be stored with overlay-provider fingerprint matching on-disk bun-bin `1.4.0`
