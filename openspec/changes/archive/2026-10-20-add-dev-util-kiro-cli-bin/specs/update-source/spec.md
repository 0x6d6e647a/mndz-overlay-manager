# update-source Specification

## ADDED Requirements

### Requirement: Kiro CLI bin manifest source

`dev-util/kiro-cli-bin` SHALL map to an HttpJson source whose only URL is `https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json` and whose version field is `version`. No update source SHALL be inferred from the ebuild.

#### Scenario: Manifest field is the comparable version

- **WHEN** resolving an update source for `dev-util/kiro-cli-bin`
- **THEN** the source is HttpJson with that single manifest URL and field `version`
- **AND** no update source is inferred from the ebuild

#### Scenario: A missing or non-string version field fails the fetch

- **WHEN** the manifest is missing, is not a JSON object, or its `version` field is missing or not a string
- **THEN** the `dev-util/kiro-cli-bin` fetch is an error
