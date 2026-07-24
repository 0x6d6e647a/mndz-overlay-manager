## ADDED Requirements

### Requirement: Apply outcomes independent of internal module layout

Apply behavior specified for `GitMvAndManifest` and `DepsAndAssets` (including hard-fail vs soft-skip classification, dirty-path checks, md5-cache gate before mutation, commit-on-unit-success, and assets publish coordination) SHALL hold regardless of how apply code is partitioned across library modules. Reorganizing apply source files SHALL NOT by itself change operator-visible update outcomes or exit-code policy.

#### Scenario: Module split does not change hard-fail folding

- **WHEN** update produces the same set of per-unit hard-fail and soft-skip outcomes before and after an internal apply module split
- **THEN** process hard-fail folding (exit failure only when any hard-fail occurred) remains the same

#### Scenario: Md5 gate still blocks before mutation

- **WHEN** a package would be updated but md5-cache is missing or mismatched for a non-live ebuild
- **THEN** the unit hard-fails without renaming or rewriting the ebuild, independent of which apply module implements the gate
