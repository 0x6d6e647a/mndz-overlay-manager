# Spec Delta

## ADDED Requirements

### Requirement: Full-path Uv uses image uv

Full-path Uv materialize SHALL run `uv` from the materialize image against the image Python interpreter. The container SHALL NOT use a host `uv` binary and SHALL NOT download a Python interpreter.

#### Scenario: Host uv is unused

- **WHEN** full-path Uv packing runs and the host has a `uv` binary
- **THEN** the container uses the image `uv` and does not download CPython
