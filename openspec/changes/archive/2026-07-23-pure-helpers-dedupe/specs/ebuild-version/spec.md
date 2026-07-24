## ADDED Requirements

### Requirement: PV without revision for filenames and tags

The library SHALL provide a single pure render of an ebuild version **without** Gentoo revision suffix for uses that need bare PV form (for example new ebuild filename version components and release/asset version tags derived from PV). Numeric versions SHALL join components with `.` and omit `-rN`. Raw versions SHALL render as their original string without inventing a leading `v`.

#### Scenario: Numeric revision stripped

- **WHEN** a numeric version `1.2.3` with revision `1` is rendered without revision
- **THEN** the result is `1.2.3`

#### Scenario: Numeric without revision unchanged

- **WHEN** a numeric version `0.84.0` without revision is rendered without revision
- **THEN** the result is `0.84.0`

### Requirement: Same-PV equality helper

The library SHALL provide a pure equality check for two ebuild versions that is true when `comparePV` reports equal (numeric components equal, revision ignored) and false when comparison is less, greater, or incomparable.

#### Scenario: Revisions do not break same-PV equality

- **WHEN** comparing `1.2.3-r1` and `1.2.3` for same-PV equality
- **THEN** equality holds

#### Scenario: Different PVs are not equal

- **WHEN** comparing `1.2.3` and `1.2.4` for same-PV equality
- **THEN** equality does not hold
