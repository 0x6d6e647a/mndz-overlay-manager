## ADDED Requirements

### Requirement: Stan configuration is repository-owned

The repository SHALL include a Stan configuration file used by the quality pipeline. The configuration MAY exclude some severities or categories with documented project intent, but the quality pipeline SHALL still invoke stan as a blocking step. Tightening excludes (enabling previously deferred severities) SHALL keep `hk check` / stan green for the committed baseline.

#### Scenario: Stan config present for pipeline

- **WHEN** a developer inspects the repository for static analysis configuration
- **THEN** a Stan configuration file exists and is what the quality pipeline uses for stan

#### Scenario: Enabled checks are passable

- **WHEN** the tree is clean relative to the committed Stan baseline and HIE is fresh
- **THEN** stan exits successfully under the quality pipeline
