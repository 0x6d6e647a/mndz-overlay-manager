# Spec Delta

## ADDED Requirements

### Requirement: README names the Pdm ecosystem

`README.md` SHALL name `Pdm` among `DepsAndAssets` ecosystems. It SHALL state that full-path Pdm packing runs in the materialize image, which provides Python and pdm. It SHALL NOT add a host `pdm` binary to the operator runtime-tool list solely for that packing.

#### Scenario: README mentions Pdm

- **WHEN** an operator reads the `DepsAndAssets` ecosystem summary
- **THEN** it names `Pdm` and states that full-path packing uses the materialize image
- **AND** the operator runtime-tool list does not gain a host `pdm` binary for that packing
