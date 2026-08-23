## ADDED Requirements

### Requirement: CONTRIBUTING documents hk fix index behavior

When `CONTRIBUTING.md` documents `hk fix` as the format entrypoint, it SHALL state at contributor depth that `hk fix` formats in place and does not stage files, and that pre-commit may restage already-staged files it formatted so the commit contains the formatted version.

#### Scenario: Contributor finds hk fix does not git add

- **WHEN** a contributor reads quality-workflow documentation for `hk fix`
- **THEN** the text states that `hk fix` does not add formatted files to the git index
