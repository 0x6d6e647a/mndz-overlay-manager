## MODIFIED Requirements

### Requirement: Optional github-token config key

The configuration schema SHALL accept an optional `github-token` string key. Absence of the key SHALL NOT fail config load for commands that do not need GitHub write access.

#### Scenario: Config without token loads

- **WHEN** the config file defines `overlay-path` but omits `github-token`
- **THEN** config load succeeds for commands that do not require a token
