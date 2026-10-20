# Spec Delta

## ADDED Requirements

### Requirement: cmake-language-server GitHub source

`dev-util/cmake-language-server` SHALL map to GitHub owner `regen100`, repository `cmake-language-server`, with tag prefix `v`. Comparable versions SHALL include a tag that parses after that prefix is stripped. No update source SHALL be inferred from the ebuild.

#### Scenario: Prefixed tags are comparable

- **WHEN** the repository has tags `v0.1.10` and `v0.1.11`
- **THEN** the comparable versions include PV `0.1.10` and PV `0.1.11`
- **AND** the source is GitHub `regen100/cmake-language-server` with tag prefix `v`
- **AND** no update source is inferred from the ebuild
