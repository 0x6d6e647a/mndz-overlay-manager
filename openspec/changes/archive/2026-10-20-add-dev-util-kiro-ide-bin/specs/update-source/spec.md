# update-source Specification

## ADDED Requirements

### Requirement: Kiro IDE bin metadata source

`dev-util/kiro-ide-bin` SHALL map to an HttpJson source whose URLs are `https://prod.download.desktop.kiro.dev/stable/metadata-linux-x64-stable.json` and `https://prod.download.desktop.kiro.dev/stable/metadata-linux-arm64-stable.json` and whose version field is `currentRelease`. The two documents MUST report the same value. No update source SHALL be inferred from the ebuild.

#### Scenario: Both stable metadata documents are the source

- **WHEN** resolving an update source for `dev-util/kiro-ide-bin`
- **THEN** the source is HttpJson with those two stable metadata URLs and field `currentRelease`
- **AND** neither URL is an insider metadata document
- **AND** no update source is inferred from the ebuild

#### Scenario: Agreeing currentRelease values are the comparable version

- **WHEN** both metadata documents have `currentRelease` `1.4.10`
- **THEN** the comparable version for `dev-util/kiro-ide-bin` is PV `1.4.10`

#### Scenario: Disagreeing currentRelease values fail the fetch

- **WHEN** the x64 document's `currentRelease` is `1.4.10` and the arm64 document's `currentRelease` is `1.4.5`
- **THEN** the `dev-util/kiro-ide-bin` fetch is an error
- **AND** no single version is reported for that package

#### Scenario: A missing or non-string currentRelease fails the fetch

- **WHEN** either metadata document is missing, is not a JSON object, or its `currentRelease` field is missing or not a string
- **THEN** the `dev-util/kiro-ide-bin` fetch is an error

#### Scenario: A non-numeric currentRelease fails the fetch

- **WHEN** both documents have `currentRelease` `latest`
- **THEN** the `dev-util/kiro-ide-bin` fetch is an error
