## ADDED Requirements

### Requirement: Document Stan baseline exclusions

When Stan is configured with severity or category excludes (for example Style, Warning, or Performance), `CONTRIBUTING.md` SHALL document the current baseline intent at contributor depth: which severities or categories are intentionally deferred or enabled, so contributors know what `hk check` / stan is expected to enforce without reverse-engineering `.stan.toml` alone.

#### Scenario: CONTRIBUTING mentions Stan baseline

- **WHEN** a contributor reads quality-workflow documentation after Stan baseline tightening
- **THEN** `CONTRIBUTING.md` states which Stan check classes are enforced versus deferred (or points to `.stan.toml` with a short summary of the baseline policy)
