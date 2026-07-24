## ADDED Requirements

### Requirement: Update source capability purpose

The update-source capability SHALL define how packages obtain upstream version information: the update-source model (GitHub, npm, Http), hardcoded package-to-source mapping, fetching latest version, and listing comparable GitHub versions for runtime-lane planning.

#### Scenario: Hardcoded map is the only resolution path

- **WHEN** resolving an update source for any package key
- **THEN** resolution uses only the hardcoded policy map as specified by the hardcoded source overrides requirement
