## ADDED Requirements

### Requirement: rulesync enabled end-to-end

`dev-util/rulesync` SHALL use runtime lanes against gentoo `net-libs/nodejs`, npm registry candidates under the shared candidate rule, deps asset publish/reuse, and overlay apply as specified for `DepsAndAssets Npm`. The package SHALL NOT soft-skip solely because npm deps assets are required.

#### Scenario: No longer unsupported

- **WHEN** policy is resolved and apply runs for an outdated `dev-util/rulesync`
- **THEN** the program does not soft-skip with reason unsupported deps assets