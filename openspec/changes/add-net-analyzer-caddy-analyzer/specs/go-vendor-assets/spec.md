# go-vendor-assets Delta

## ADDED Requirements

### Requirement: Preserve Go donor build and local patch contracts

Go apply SHALL preserve donor-owned compile, test, install, completion, and optional-dependency behavior when updating assets URLs, Go BDEPEND, KEYWORDS, or the ebuild filename. Apply SHALL preserve explicit `FILESDIR` and `PATCHES` references and their package-local files. It SHALL NOT automatically rebase, rename, remove, or replace a local patch to make an update succeed. A later failed verification SHALL NOT produce a successful package result or signed overlay success commit; existing late-failure diagnostics and temporary-workspace retention SHALL apply.

#### Scenario: Caddy analyzer donor survives a PV bump

- **WHEN** Go apply updates caddy-analyzer using a donor with an explicit `caddy-analyzer-0.7.4-offline-geoip.patch` reference
- **THEN** the new ebuild preserves that reference, `CGO_ENABLED=0`, version injection, `dobin caddy-analyze`, completion generation, test gating, temporary test configuration, and firewall dependency notices
- **AND** only the update-owned fields change

#### Scenario: Verification failure does not become a success commit

- **WHEN** a caddy-analyzer update fails Manifest or asset-digest verification
- **THEN** the unit hard-fails without a successful signed overlay commit or success line
- **AND** any already-published asset is reported according to the existing orphan-assets warning contract
