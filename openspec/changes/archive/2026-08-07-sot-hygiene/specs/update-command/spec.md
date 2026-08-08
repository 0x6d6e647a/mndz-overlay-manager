## RENAMED Requirements

- FROM: `### Requirement: Update phase-one multi-progress when enabled`
- TO: `### Requirement: Update package-apply multi-progress when enabled`

## MODIFIED Requirements

### Requirement: Update package-apply multi-progress when enabled

When activity indicators are enabled, `update` package-apply work SHALL show multi-progress (top-level done/total and per-package rows) as specified by `cli-activity`. For `DepsAndAssets` (and similarly long techniques), the package row SHALL update short sub-phase labels and advance per-package step progress during work without requiring nested progress bars. For full-path Go vendor materialize, labels and steps SHALL follow the fine-grained sequence specified by `cli-activity` (clone, go mod download, compress, commit assets, push assets, upload release asset, regenerating manifest). For reuse-path materialize, labels and steps SHALL follow the reuse sequence specified by `cli-activity`.

#### Scenario: Go package shows sub-phase label

- **WHEN** indicators are enabled and a `DepsAndAssets` Go package is being applied
- **THEN** the package’s multi-progress row includes a short sub-phase description that can change as the technique advances

#### Scenario: Go full path advances materialize sub-phases

- **WHEN** indicators are enabled and a `DepsAndAssets` Go package PV is materialized on the full vendor+publish path
- **THEN** the package row’s sub-phase description and step progress advance through vendor construction and assets publish sub-phases as specified by `cli-activity`, not only a single frozen vendoring or publishing label for those phases
