## ADDED Requirements

### Requirement: Ebuild version type

The library SHALL provide an ebuild version type that represents either a numeric version with an optional Gentoo-style revision (`-rN`) or a raw unparsed version string for non-numeric forms.

#### Scenario: Numeric version with revision

- **WHEN** the version string `1.5.3-r2` is parsed successfully as numeric
- **THEN** the value has components corresponding to `1`, `5`, `3` and revision `2`

#### Scenario: Numeric version without revision

- **WHEN** the version string `0.2.93` is parsed successfully as numeric
- **THEN** the value has components corresponding to `0`, `2`, `93` and no revision

#### Scenario: Non-numeric falls back to raw

- **WHEN** a version string cannot be parsed as numeric components with optional revision
- **THEN** the library represents it as a raw version preserving the original string

### Requirement: Pretty render with leading v

The library SHALL provide a pretty-render function for display that prefixes a successful numeric (or raw) version with `v` and includes `-rN` when a revision is present (e.g. `v1.5.3-r2`). The leading `v` is display-only and SHALL NOT be required in stored or compared PV form.

#### Scenario: Render local version with revision

- **WHEN** a numeric version `1.5.3` with revision `2` is pretty-rendered
- **THEN** the result is `v1.5.3-r2`

#### Scenario: Render version without revision

- **WHEN** a numeric version `2.1.10` without revision is pretty-rendered
- **THEN** the result is `v2.1.10`

### Requirement: PV comparison for updates

The library SHALL compare two ebuild versions for update detection by numeric component order only, ignoring revision. Comparison of two numeric versions SHALL be well-ordered by components (not lexicographic string order). If either side is raw or otherwise incomparable, comparison SHALL report incomparable rather than guessing order.

#### Scenario: Newer remote is greater

- **WHEN** local PV is `1.17.16` and remote PV is `1.17.18`
- **THEN** comparison reports local less than remote (outdated)

#### Scenario: Revision does not make local newer than same PV upstream

- **WHEN** local version is `1.2.3-r5` and remote version is `1.2.3`
- **THEN** comparison reports equal for update purposes

#### Scenario: Multi-digit components order numerically

- **WHEN** comparing `1.10.0` and `1.9.0`
- **THEN** `1.10.0` is greater than `1.9.0`

#### Scenario: Incomparable raw

- **WHEN** one side is raw and the other is numeric
- **THEN** comparison reports incomparable
