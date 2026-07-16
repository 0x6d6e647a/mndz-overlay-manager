## ADDED Requirements

### Requirement: Update preflight progress when enabled

When activity indicators are enabled, `update` SHALL show a sequential preflight progress bar covering preflight steps (tool checks and any conditional assets/token/ssh-agent preparation that runs before package mutation). The bar SHALL clear when preflight finishes or fails (failure logs after clear or without a panel when indicators are disabled).

#### Scenario: Preflight shows step progress on TTY

- **WHEN** the user runs `update` with indicators enabled
- **THEN** a sequential preflight progress bar is displayed before package mutation work begins

### Requirement: Update phase-one multi-progress when enabled

When activity indicators are enabled, `update` phase-1 package apply SHALL show multi-progress (top-level done/total and per-package rows) as specified by `cli-activity`. For `GoVendorAndAssets` (and similarly long techniques), the package row SHALL update a short sub-phase label during work (for example fetching, vendoring, publishing assets, regenerating manifest) without requiring nested progress bars.

#### Scenario: Go package shows sub-phase label

- **WHEN** indicators are enabled and a `GoVendorAndAssets` package is being applied
- **THEN** the package’s multi-progress row includes a short sub-phase description that can change as the technique advances

### Requirement: Update commit progress when enabled

When activity indicators are enabled and one or more packages proceed to signed commit, `update` SHALL show a sequential commit progress bar (done/total and current package), not multi-row spinners, and SHALL clear it when the commit phase ends.

#### Scenario: Commit phase bar on TTY

- **WHEN** indicators are enabled and two packages are committed
- **THEN** a sequential commit progress bar advances through both commits and then clears

### Requirement: Deferred update outcome emission

When activity indicators were shown for a phase, the program SHALL emit success stdout lines and soft/hard log messages for that work only after the relevant panel is cleared. Soft-skip and hard-fail packages SHALL remain visible on multi-progress rows until the phase panel clears. Machine stdout success format SHALL remain `category/package vLOCAL -> vREMOTE`.

#### Scenario: Success stdout after clear

- **WHEN** indicators are enabled and a package is successfully updated and committed
- **THEN** its success stdout line is written only after progress panels for the completed work have been cleared

#### Scenario: Soft skip stays on panel then logs

- **WHEN** indicators are enabled and a package is soft-skipped during phase 1
- **THEN** the package remains on the multi-progress panel in a non-success state until clear, after which the warning is logged
