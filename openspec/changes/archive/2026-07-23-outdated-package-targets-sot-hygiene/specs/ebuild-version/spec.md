## ADDED Requirements

### Requirement: Ebuild version capability purpose

The ebuild-version capability SHALL define parse, pretty-render (PV form without leading `v`), and PV comparison (revision ignored for update ordering) for ebuild version strings used by discovery, outdated, and update flows.

#### Scenario: Capability used for update ordering

- **WHEN** outdated or update compares local and remote versions
- **THEN** comparison uses the ebuild-version PV rules (numeric components; revision ignored for equality with same PV)
