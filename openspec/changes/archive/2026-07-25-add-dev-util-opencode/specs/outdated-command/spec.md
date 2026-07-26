## MODIFIED Requirements

### Requirement: Non-Go outdated unchanged

Packages that are not `DepsAndAssets` SHALL continue to use newest-local vs single fetched latest comparison and the single-line `category/package LOCAL -> REMOTE` format (PV form, no leading `v`) without runtime-lane labels.

#### Scenario: Binary package format

- **WHEN** `dev-util/grok-build-bin` is outdated
- **THEN** stdout uses a single unlabeled line
