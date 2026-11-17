# Spec Delta

## ADDED Requirements

### Requirement: README documents the smoke compile cache

`README.md` SHALL document the `mndz-smoke-compile-cache` volume and its per-package layout, which caches it holds, `--no-compile-cache`, `--reset-compile-cache`, the `smoke-compile-cache-max-size` config key and its default, the 30-day and free-space cleanup rules, and that removing the whole volume is manual.

#### Scenario: Operator wants to reclaim the space

- **WHEN** an operator reads the smoke environment section of `README.md`
- **THEN** it names `mndz-smoke-compile-cache`, the size budget key, and how to reset one package's cache

### Requirement: README records the Go trim workaround as fragile

`README.md` SHALL state that the Go build cache relies on an undocumented `go` command internal to stop Go's own trimming, that a Go release may stop honoring it, that `smoke` warns when its check finds that, and that builds still succeed when it happens.

#### Scenario: Trim check warning

- **WHEN** an operator sees the warning that Go cache trimming is not suppressed
- **THEN** the README explains what it means and that only cache reuse is affected
