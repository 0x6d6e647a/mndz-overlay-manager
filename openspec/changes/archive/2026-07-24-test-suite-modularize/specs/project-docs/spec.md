## ADDED Requirements

### Requirement: Contributor documentation of test layout

When the test suite is organized into multiple modules under a standard harness (rather than a single monolithic test Main with only hand-rolled asserts), `CONTRIBUTING.md` SHALL document how to run the full test suite (`cabal test all` and/or `hk check`) and, when practical, how to select a subset of tests with the harness’s filter mechanism.

#### Scenario: CONTRIBUTING documents test run

- **WHEN** a contributor reads `CONTRIBUTING.md` for quality workflows after the modular suite lands
- **THEN** the file describes how to run the project tests as part of the quality workflow
- **AND** if a harness filter is supported, the file mentions how to run a subset (or points at the harness’s standard filter flag)
