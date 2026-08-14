## ADDED Requirements

### Requirement: README run-id example is PATH-safe

When `README.md` documents the product temporary workspace layout under `$TMPDIR/mndz/overlay-manager/<run-id>/`, it SHALL include at least one example run-id in ISO 8601 **basic** form with numeric offset and no `:` (for example `20260810T154207-0700-4242.a8f3`). It SHALL NOT present the extended colon form (`2026-08-10T15:42:07-07:00-…`) as the on-disk run-id example.

#### Scenario: Operator sees a colon-free run-id example

- **WHEN** an operator reads the temporary workspace layout in `README.md`
- **THEN** any concrete run-id example is PATH-safe ISO 8601 basic and does not contain `:`
