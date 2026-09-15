## MODIFIED Requirements

### Requirement: opencode and openspec gain gated src_test

`dev-util/opencode` and `dev-util/openspec` SHALL each declare `IUSE` including `test`, set `RESTRICT` including `!test? ( test )` (opencode SHALL retain its existing `strip` restriction by merging tokens), define `src_test` that runs an upstream test command using the package’s deps layout, and publish content-only gate fixes as revision bumps.

For `dev-util/opencode`, `src_test` SHALL `cd` to `packages/cli` and SHALL invoke `bun-<exact> test --timeout 30000 --only-failures` (or an equivalent failure-checked bun test entrypoint using the compile-pin bun-bin). The ebuild SHALL NOT skip, `|| true`, or otherwise ignore test failures. Known failing cases (ACP subprocess JSON-RPC parse; standalone pid-namespace kill) MAY remain failing until a later change; they SHALL NOT be filtered out solely to make `FEATURES=test` green.

#### Scenario: opencode merges strip and test RESTRICT

- **WHEN** the live opencode ebuild is inspected
- **THEN** `RESTRICT` includes both `strip` and `!test? ( test )`
- **AND** `IUSE` includes `test`
- **AND** `src_test` is defined and invokes `bun-<exact> test` from `packages/cli` when the test phase runs
- **AND** the ebuild is a `-rN` revision when the gate or v2 retarget was content-only relative to an unrevised prior live file

#### Scenario: opencode src_test does not skip failures

- **WHEN** `USE=test` and `FEATURES=test` run `src_test` for opencode and the bun test suite reports failures
- **THEN** the test phase fails (non-zero / `die`)
- **AND** the ebuild does not exclude `*.subprocess.test.ts` solely to hide those failures

#### Scenario: openspec has gated npm-oriented tests

- **WHEN** the live openspec ebuild is inspected
- **THEN** `IUSE` includes `test` and `RESTRICT` includes `!test? ( test )`
- **AND** `src_test` is defined and invokes an offline-appropriate test entrypoint when the test phase runs
- **AND** the ebuild is a `-rN` revision when the gate was content-only relative to an unrevised prior live file
