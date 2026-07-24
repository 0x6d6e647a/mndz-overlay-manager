## MODIFIED Requirements

### Requirement: Weeder configuration

The repository SHALL include a weeder configuration that defines roots appropriate to this package (including executable and test entrypoints as needed) so dead-code analysis is meaningful for a library-plus-executable layout. Weeder configuration SHALL NOT list every library module as a blanket `root-modules` entry solely to suppress weeds on an application-internal library surface. Roots SHALL reflect real program entrypoints and any intentionally public exports that are justified in the configuration comments or project docs.

#### Scenario: Weeder runs with project config

- **WHEN** weeder is invoked as part of the quality pipeline with HIE files present
- **THEN** weeder uses the repository weeder configuration file and exits non-zero only when it reports weeds (or a tool error), not because configuration is missing

#### Scenario: Roots are not a full-module blanket

- **WHEN** a reader inspects the committed weeder configuration
- **THEN** `root-modules` does not enumerate essentially the entire library module set without entrypoint-oriented justification
