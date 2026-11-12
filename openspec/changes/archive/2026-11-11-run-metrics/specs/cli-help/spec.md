# Spec Delta

## ADDED Requirements

### Requirement: Help documents the no-metrics flag

The top-level usage/help text SHALL document the global option `--no-metrics`, stating that it turns off run metrics recording for that invocation and that work commands otherwise require GNU `/usr/bin/time`.

#### Scenario: Help mentions no-metrics

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes `--no-metrics`
