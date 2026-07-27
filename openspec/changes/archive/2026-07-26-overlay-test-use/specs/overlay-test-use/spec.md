## ADDED Requirements

### Requirement: Overlay test USE and RESTRICT convention

Every non-prebuilt mndz-overlay package that exposes a Portage test phase SHALL declare `test` in `IUSE` and SHALL set `RESTRICT` to include `!test? ( test )` (merged with any other RESTRICT tokens) so Portage skips the test phase when `USE=-test` even if `FEATURES` includes `test`.

Prebuilt packages (`dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`) are exempt from this requirement.

#### Scenario: Compliant package has both tokens

- **WHEN** a non-prebuilt package ebuild that defines or inherits a non-empty test phase is inspected after this change
- **THEN** its `IUSE` includes `test`
- **AND** its `RESTRICT` includes the conditional token list `!test? ( test )`

#### Scenario: badger remains the reference shape

- **WHEN** `dev-db/badger` is inspected
- **THEN** it already satisfies the convention (`IUSE` includes `test`, `RESTRICT` includes `!test? ( test )`, and `src_test` runs Go tests)
- **AND** this change does not require a content-only revbump solely to restate that compliance

### Requirement: Mandatory revision bump for non-version ebuild content edits

When mndz-overlay ebuild content changes without changing the upstream package version (`PV`), the change SHALL be published as a new Portage revision (`-rN`): the live ebuild filename SHALL be `${PN}-${PV}-rN.ebuild` with N greater than any previous revision for that PV (or `-r1` if the previous live file was unrevised `${PN}-${PV}.ebuild`). In-place content edits that leave the same live ebuild path as the final result without a revision increase SHALL NOT be used for such fixes.

#### Scenario: Content-only fix increases revision

- **WHEN** an ebuild is modified only for IUSE, RESTRICT, `src_test`, or other non-PV content under this change
- **THEN** the published ebuild path uses the next `-rN` for that PV
- **AND** Manifest and package md5-cache entries match the new revision

#### Scenario: Unrevised file becomes -r1

- **WHEN** the previous live ebuild was `category/package/package-1.2.3.ebuild` with no revision suffix
- **THEN** the content fix is published as `category/package/package-1.2.3-r1.ebuild` (not an overwrite of `package-1.2.3.ebuild` as the sole live file without revbump)

### Requirement: ralph-tui test USE gate

The mndz-overlay package `dev-util/ralph-tui` SHALL declare `IUSE` including `test` and SHALL set `RESTRICT` including `!test? ( test )`. `src_test` SHALL invoke the package test command (`bun test`) when the test phase runs. The content fix SHALL ship as a revision bump of the current PV.

#### Scenario: RESTRICT present after revbump

- **WHEN** the live ralph-tui ebuild is inspected after this change
- **THEN** it is a `-rN` ebuild for the prior PV (or higher N if already revised)
- **AND** it contains `RESTRICT` including `!test? ( test )`
- **AND** it still offers `test` in `IUSE`

#### Scenario: src_test runs bun test when enabled

- **WHEN** `USE=test` and `FEATURES=test` allow the test phase for ralph-tui
- **THEN** `src_test` invokes `bun test` (or equivalent failure-checked bun test entrypoint)

### Requirement: Go packages with existing suites are USE-gated

`dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL each declare `IUSE` including `test`, set `RESTRICT` including `!test? ( test )`, retain a `src_test` that runs the package Go tests (`ego test` or equivalent), and publish those content changes as revision bumps.

#### Scenario: dolt gated

- **WHEN** the live dolt ebuild is inspected after this change
- **THEN** it includes `test` in `IUSE` and `!test? ( test )` in `RESTRICT`
- **AND** `src_test` still runs Go tests
- **AND** the ebuild filename is a revision bump relative to the pre-change live revision

#### Scenario: beads and crush gated

- **WHEN** the live beads and crush ebuilds are inspected after this change
- **THEN** each satisfies the same IUSE, RESTRICT, `src_test`, and `-rN` rules as dolt

### Requirement: Cargo packages gate inherited cargo_src_test

`dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL each declare `IUSE` including `test` and set `RESTRICT` including `!test? ( test )` so the cargo.eclass-exported test phase is skipped when `USE=-test`. When `USE=test` and `FEATURES=test` allow the phase, tests SHALL run via `cargo_src_test` (default eclass export or an explicit wrapper that invokes it). Content changes SHALL ship as revision bumps. Optional `CARGO_SKIP_TESTS` or documented skips MAY be used for known-broken offline cases without removing the USE gate.

#### Scenario: mise RESTRICT gates cargo tests

- **WHEN** the live mise ebuild is inspected after this change
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`
- **AND** the ebuild is a `-rN` revision bump for the prior PV
- **AND** no override disables the cargo test phase when USE and FEATURES allow tests (other than documented skips)

#### Scenario: hk and usage match mise

- **WHEN** the live hk and usage ebuilds are inspected after this change
- **THEN** each satisfies the same IUSE, RESTRICT, cargo test, and `-rN` rules as mise

### Requirement: opencode and openspec gain gated src_test

`dev-util/opencode` and `dev-util/openspec` SHALL each declare `IUSE` including `test`, set `RESTRICT` including `!test? ( test )` (opencode SHALL retain its existing `strip` restriction by merging tokens), define `src_test` that runs an offline-appropriate upstream test command using the package’s deps layout, and publish as revision bumps.

#### Scenario: opencode merges strip and test RESTRICT

- **WHEN** the live opencode ebuild is inspected after this change
- **THEN** `RESTRICT` includes both `strip` and `!test? ( test )`
- **AND** `IUSE` includes `test`
- **AND** `src_test` is defined and invokes a Bun-based test entrypoint when the test phase runs
- **AND** the ebuild is a `-rN` revision for the prior PV

#### Scenario: openspec has gated npm-oriented tests

- **WHEN** the live openspec ebuild is inspected after this change
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`
- **AND** `src_test` is defined and invokes an offline-appropriate test entrypoint when the test phase runs
- **AND** the ebuild is a `-rN` revision for the prior PV
