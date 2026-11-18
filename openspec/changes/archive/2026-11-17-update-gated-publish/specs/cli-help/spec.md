# Spec Delta

## ADDED Requirements

### Requirement: Update help describes gated publishing

`update --help` SHALL state that every update is smoke-tested before anything is published or committed. It SHALL state that successful updates are committed and the overlay is pushed. It SHALL document `--no-compile-cache` as running the gate's smoke runs without the per-package compile cache.

#### Scenario: Gate and push in help

- **WHEN** the user runs `update --help`
- **THEN** the usage text mentions the smoke test before publishing and the overlay push
- **AND** it documents `--no-compile-cache`
