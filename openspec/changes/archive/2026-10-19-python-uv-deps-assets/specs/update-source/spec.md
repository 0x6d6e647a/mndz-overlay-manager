# Spec Delta

## ADDED Requirements

### Requirement: codex-as-mcp GitHub source

`dev-util/codex-as-mcp` SHALL map to GitHub owner `kky42`, repository `codex-as-mcp`, with tag prefix `v`. Comparable versions SHALL include a tag that parses after that prefix is stripped and a numeric tag that does not start with the prefix. No update source SHALL be inferred from the ebuild.

#### Scenario: Both tag spellings are comparable

- **WHEN** the repository has tags `2026.2.2.1` and `v2026.6.29.1`
- **THEN** the comparable versions include PV `2026.2.2.1` and PV `2026.6.29.1`
- **AND** the source is GitHub `kky42/codex-as-mcp` with tag prefix `v`
- **AND** no update source is inferred from the ebuild
