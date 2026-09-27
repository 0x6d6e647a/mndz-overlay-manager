# Spec Delta

## MODIFIED Requirements

### Requirement: Overlay test USE and RESTRICT convention

Every non-prebuilt mndz-overlay package that exposes a Portage test phase SHALL declare `test` in `IUSE` and SHALL set `RESTRICT` to include `!test? ( test )` (merged with any other RESTRICT tokens) so Portage skips the test phase when `USE=-test` even if `FEATURES` includes `test`.

Prebuilt packages (`dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, `dev-util/grok-bot-bin`) are exempt from this requirement.

#### Scenario: Compliant package has both tokens

- **WHEN** a non-prebuilt package ebuild that defines or inherits a non-empty test phase is inspected
- **THEN** its `IUSE` includes `test`
- **AND** its `RESTRICT` includes the conditional token list `!test? ( test )`

#### Scenario: badger remains the reference shape

- **WHEN** `dev-db/badger` is inspected
- **THEN** it satisfies the convention (`IUSE` includes `test`, `RESTRICT` includes `!test? ( test )`, and `src_test` runs Go tests)
- **AND** a content-only revbump is not required solely to restate that compliance

#### Scenario: Grok Bot is prebuilt

- **WHEN** `dev-util/grok-bot-bin` is inspected
- **THEN** it is exempt from the `IUSE=test` convention
- **AND** its `IUSE` does not include `test`
