## MODIFIED Requirements

### Requirement: Document DepsAndAssets operator tools

When this change lands operator-facing `update` behavior for npm, Bun, or Cargo packages, project docs SHALL state that `update` of packages that publish Go vendor, npm/Bun deps, or Cargo crates assets may require `go` and/or `npm` and/or `bun` and/or `pycargoebuild` plus a fetcher (`wget` or `aria2c`) as applicable, in addition to existing tools (`xz`, assets path, token). README (or equivalent operator surface) SHALL mention `DepsAndAssets` ecosystems at a high level without re-hosting full pipeline tables in AGENTS.md. CONTRIBUTING and AGENTS SHALL NOT pin `pycargoebuild` in project-local `.tools/bin` install scripts; operator runtimes remain documented in README only unless CONTRIBUTING already lists go/npm/bun as application runtimes in the same section.

#### Scenario: README lists language tools

- **WHEN** operator documentation is updated for this change
- **THEN** it names `npm` and `bun` as conditional runtime tools for deps asset packages alongside `go` for vendor packages

#### Scenario: README lists pycargoebuild for cargo

- **WHEN** operator documentation is updated for cargo crates assets
- **THEN** it names `pycargoebuild` and a supported fetcher as conditional runtime tools for cargo packages
