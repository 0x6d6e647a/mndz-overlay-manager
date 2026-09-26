# npm-deps-assets Delta

## ADDED Requirements

### Requirement: claude-agent-acp enabled end-to-end

`dev-util/claude-agent-acp` SHALL use runtime lanes against gentoo `net-libs/nodejs`, npm registry candidates for `@agentclientprotocol/claude-agent-acp` under the shared candidate rule, deps asset publish/reuse, and overlay apply as specified for `DepsAndAssets Npm`. The package SHALL NOT soft-skip solely because npm deps assets are required. The hardcoded policy source SHALL be npm package `@agentclientprotocol/claude-agent-acp`.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/claude-agent-acp`
- **THEN** the program does not soft-skip with reason unsupported deps assets

#### Scenario: Scoped registry package

- **WHEN** full-path materialize packs a PV for this package
- **THEN** `npm pack` uses `@agentclientprotocol/claude-agent-acp` at that PV
- **AND** the deps distfile basename uses PN `claude-agent-acp`
