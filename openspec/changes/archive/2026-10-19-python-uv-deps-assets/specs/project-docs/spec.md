# Spec Delta

## ADDED Requirements

### Requirement: README names the Uv ecosystem

`README.md` SHALL name `Uv` among `DepsAndAssets` ecosystems. It SHALL state that full-path Uv packing runs in the materialize image, which provides Python, uv, and Rust. It SHALL NOT add a host `uv` binary to the operator runtime-tool list solely for that packing.

#### Scenario: README mentions Uv

- **WHEN** an operator reads the `DepsAndAssets` ecosystem summary
- **THEN** it names `Uv` and states that full-path packing uses the materialize image
- **AND** the operator runtime-tool list does not gain a host `uv` binary for that packing
