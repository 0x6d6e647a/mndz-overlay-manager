## ADDED Requirements

### Requirement: Closure and keep scans do not drop an unreadable ebuild

When atom closure, GitMv rename-away, or reverse-dep keep reads another package's non-live ebuilds, that read SHALL be one observation of names and complete bodies. The program SHALL NOT omit an ebuild whose read failed and then treat the remaining set as the full consumer or provider set. If an ebuild included in the observation cannot be read, the unit SHALL hard-fail without renaming, rewriting, or deleting an overlay ebuild. The message SHALL name the path. Other selected packages SHALL continue.

An observation that finds the publishing package's overlay-internal atoms satisfied SHALL be the same exclusion hold as that package's following ebuild rename, content write, or deletion, as specified by `update-apply`. After the package waits for a provider, it SHALL observe again and SHALL publish only when the new observation shows the atoms satisfied.

#### Scenario: A raced read does not hide a consumer pin

- **WHEN** a GitMv rename-away guard reads a consumer ebuild while that consumer ebuild is being rewritten or renamed by a concurrent admitted package
- **THEN** the guard uses either the complete pre-publish body or the complete post-publish body
- **AND** the guard does not allow the rename solely because the consumer ebuild was missing from a torn read

#### Scenario: Unreadable consumer ebuild fails the provider unit

- **WHEN** reverse-dep keep or rename-away cannot read a consumer ebuild path it listed
- **THEN** the provider unit hard-fails without pruning or renaming
- **AND** the message names that path
- **AND** other selected packages may still succeed

#### Scenario: Wait then publish re-reads the tree

- **WHEN** package C waits for provider P and P then reaches a non-hard-fail terminal overlay outcome that satisfies C
- **THEN** C publishes its ebuild only after a new observation, taken in the same exclusion hold as that publish, shows C's overlay-internal atoms satisfied
