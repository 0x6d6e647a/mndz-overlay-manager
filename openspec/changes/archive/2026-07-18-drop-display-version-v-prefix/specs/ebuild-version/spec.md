## REMOVED Requirements

### Requirement: Pretty render with leading v

**Reason:** Display versions should match Gentoo PV form and the rest of this tool (ebuild names, commits, assets tags), which never use a leading `v`. The prefix was cosmetic only and conflicted with bare-PV conventions.

**Migration:** Use the replacement requirement “Pretty render as PV form.” Call sites of `prettyVersion` continue to work; the implementation emits the same string as stored PV render (optional `-rN`, no leading `v`).

## ADDED Requirements

### Requirement: Pretty render as PV form

The library SHALL provide a pretty-render function for display that renders a version in PV form: numeric components joined by `.`, with `-rN` when a revision is present, and without a leading `v` (e.g. `1.5.3-r2`). Raw versions SHALL be rendered as their original string without adding a `v` prefix. Display form SHALL match stored/compared PV render for the same value.

#### Scenario: Render local version with revision

- **WHEN** a numeric version `1.5.3` with revision `2` is pretty-rendered
- **THEN** the result is `1.5.3-r2`

#### Scenario: Render version without revision

- **WHEN** a numeric version `2.1.10` without revision is pretty-rendered
- **THEN** the result is `2.1.10`
