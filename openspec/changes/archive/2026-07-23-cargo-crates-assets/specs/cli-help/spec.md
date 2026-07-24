## ADDED Requirements

### Requirement: Update help acknowledges cargo operator tools when documented

When operator-facing documentation or command-scoped update help lists conditional language/runtime tools for `DepsAndAssets`, it SHALL include `pycargoebuild` (and a crates.io fetcher such as `wget` or `aria2c`) among tools that may be required for cargo packages, consistent with README accuracy requirements in `project-docs`.

#### Scenario: README or update help names pycargoebuild

- **WHEN** an operator reads the documented runtime tools for `update` after this change
- **THEN** `pycargoebuild` is named as a conditional requirement for cargo `DepsAndAssets` packages
