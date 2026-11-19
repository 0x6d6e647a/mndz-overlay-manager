# Spec Delta

## ADDED Requirements

### Requirement: Help documents priority options

Top-level help SHALL document `--nice`, `--ionice-class` and `--ionice-level` with their valid values. It SHALL state that values are absolute, that the manager never raises its inherited priority, that container workloads follow the manager's priority, and that I/O priority depends on the disk's I/O scheduler.

#### Scenario: Help mentions priority options

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes `--nice`, `--ionice-class` and `--ionice-level`
- **AND** the text notes that I/O priority depends on the I/O scheduler
