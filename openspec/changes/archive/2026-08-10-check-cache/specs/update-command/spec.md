## ADDED Requirements

### Requirement: Update uses check cache

The `update` command SHALL load and consult the shared check cache for packages that perform latest-version fetch or runtime-lane planning when the cache is enabled and `--refresh` was not passed. On a valid hit, apply SHALL use the cached remote PV or runtime-lane plan without repeating that network work. After successful live fetch or plan during apply, and after successful package apply when rewriting is required, the command SHALL store or rewrite eligible entries when the cache is enabled. The command SHALL emit the check-cache hit/fetch info summary as specified by `check-cache`. Functional soft-skip and hard-fail rules for packages SHALL remain unchanged aside from the source of remote or plan data.

#### Scenario: Outdated then update reuses plan

- **WHEN** the user runs `outdated` and then `update` within the effective TTL without `--refresh` and without local fingerprint changes for a package that was checked
- **THEN** `update` may apply that package using cached remote or plan data without repeating the corresponding upstream discovery network work

#### Scenario: Update stores on live plan

- **WHEN** `update` performs a live deps plan because of a cache miss and the plan succeeds
- **THEN** an eligible deps cache entry is stored when the cache is enabled

### Requirement: Update refresh flag

The `update` subcommand SHALL accept a `--refresh` flag that forces live upstream latest fetch and deps plan work for packages that need that work, ignoring existing cache entries for reads, and SHALL write fresh eligible entries when the cache is enabled.

#### Scenario: Update refresh forces live fetch

- **WHEN** the user runs `update --refresh` for a package with a valid latest cache entry
- **THEN** the program performs a live latest-version fetch (or live plan for deps) rather than using the existing entry for reads
