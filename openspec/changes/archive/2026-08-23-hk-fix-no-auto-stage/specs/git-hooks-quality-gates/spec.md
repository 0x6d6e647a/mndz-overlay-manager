## ADDED Requirements

### Requirement: hk fix does not stage formatted files

The project’s `hk fix` entrypoint SHALL format selected Haskell sources in place and SHALL NOT stage those files (it SHALL NOT add them to the git index). Pre-commit MAY restage files that were **already staged** when it formats them, and SHALL stash unstaged hunks before that format so unstaged work is not pulled into the commit. `hk check` SHALL NOT format in place and SHALL NOT stage files as part of the format step.

#### Scenario: hk fix leaves the index unchanged

- **WHEN** a contributor or agent runs `hk fix` and ormolu rewrites one or more tracked Haskell files
- **THEN** those files are updated on disk
- **AND** they are not staged solely because `hk fix` ran

#### Scenario: Pre-commit restages already-staged formatted files

- **WHEN** a contributor has staged Haskell files, has unstaged hunks in the worktree, and creates a commit
- **THEN** pre-commit may format and restage the already-staged files
- **AND** the unstaged hunks are not staged solely because of that format

#### Scenario: hk check does not stage

- **WHEN** a contributor runs `hk check` and sources are already ormolu-clean
- **THEN** the format step does not modify files
- **AND** the git index is not changed by that step
