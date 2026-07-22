## ADDED Requirements

### Requirement: Document DepsAndAssets operator tools

When this change lands operator-facing `update` behavior for npm and Bun packages, project docs SHALL state that `update` of packages that publish Go vendor or npm/Bun deps assets may require `go` and/or `npm` and/or `bun` (as applicable) in addition to existing tools (`xz`, assets path, token). README (or equivalent operator surface) SHALL mention `DepsAndAssets` ecosystems at a high level without re-hosting full pipeline tables in AGENTS.md.

#### Scenario: README lists language tools

- **WHEN** operator documentation is updated for this change
- **THEN** it names `npm` and `bun` as conditional runtime tools for deps asset packages alongside `go` for vendor packages
