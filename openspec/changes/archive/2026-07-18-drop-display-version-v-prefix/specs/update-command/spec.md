## MODIFIED Requirements

### Requirement: Update stdout for successful bumps

For each non-Go package successfully updated and committed, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, using the same version pretty-rendering conventions as `outdated` (PV form, no leading `v`). For `GoVendorAndAssets` packages, stdout SHALL follow the Go tree-lane update stdout requirement (possibly multiple labeled lines). Packages that are soft-skipped or hard-failed SHALL NOT produce a success stdout line.

#### Scenario: Successful update line

- **WHEN** `dev-util/opencode-bin` is updated from local PV `1.17.19` to remote `1.17.20` and the signed commit succeeds
- **THEN** stdout contains the line `dev-util/opencode-bin 1.17.19 -> 1.17.20`

### Requirement: Go tree-lane update stdout

For each successfully applied Go tree lane (or coalesced same-PV apply that satisfies one or more lanes), the program SHALL write stdout lines of the form `category/package FROM -> TO (dev-lang/go …)` using lane labels from `go-tree-lanes`. Versions in these lines SHALL be pretty-rendered in PV form (no leading `v`). Split mapping: one local → multiple news yields one line per target with the same `FROM`. Converge mapping: multiple locals → one new yields one line per local `FROM` to that `TO`. Soft-skipped or hard-failed lanes SHALL NOT produce success lines.

When a success line corresponds to a PV that was materialized via the **reuse** path (existing release asset; no vendor rebuild/publish for that PV), the program SHALL append the token ` [assets reused]` to that line. Lines for PVs materialized via the full vendor+publish path SHALL NOT include that token.

#### Scenario: Split success lines

- **WHEN** a Go package had local `0.80.0` only and successfully materializes targets `0.82.0` and `0.84.0` for two lanes via the full path
- **THEN** stdout includes `… 0.80.0 -> 0.82.0 (…)` and `… 0.80.0 -> 0.84.0 (…)` with the correct lane labels and without requiring ` [assets reused]`

#### Scenario: Converge success lines

- **WHEN** locals `0.80.0` and `0.82.0` successfully converge to `0.84.0`
- **THEN** stdout includes `… 0.80.0 -> 0.84.0` and `… 0.82.0 -> 0.84.0` with appropriate labels

#### Scenario: Reuse success marked

- **WHEN** a planned PV is successfully completed via the reuse path
- **THEN** each success stdout line for that PV includes the substring ` [assets reused]`

### Requirement: Deferred update outcome emission

When activity indicators were shown for a phase, the program SHALL emit success stdout lines and soft/hard log messages for that work only after the relevant panel is cleared. Soft-skip and hard-fail packages SHALL remain visible on multi-progress rows until the phase panel clears. Machine stdout success format SHALL remain `category/package LOCAL -> REMOTE` (PV form, no leading `v`).

#### Scenario: Success stdout after clear

- **WHEN** indicators are enabled and a package is successfully updated and committed
- **THEN** its success stdout line is written only after progress panels for the completed work have been cleared

#### Scenario: Soft skip stays on panel then logs

- **WHEN** indicators are enabled and a package is soft-skipped during phase 1
- **THEN** the package remains on the multi-progress panel in a non-success state until clear, after which the warning is logged
