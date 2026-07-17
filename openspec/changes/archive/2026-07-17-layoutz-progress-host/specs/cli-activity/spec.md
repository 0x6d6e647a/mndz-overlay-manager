## MODIFIED Requirements

### Requirement: layoutz-backed presentation

Activity indicators SHALL be implemented using the `layoutz` library for rendering progress bars, spinners, and related chrome. Multi-progress panels and sequential step-bar panels SHALL be hosted by layoutz inline or application runtime redraw (for example `runInline` / `LayoutzApp` or equivalent), such that multi-line frame geometry and clear-on-exit for those panels are not implemented by a project-owned ANSI cursor/line-count frame writer. Log severity formatting SHALL NOT be required to use `layoutz`. Enablement gating, stderr-only indicator output, log hold during panels, multi-progress row rules, sequential step bars, and clear-before-deferred-output behavior SHALL remain as specified by the other `cli-activity` requirements.

#### Scenario: Progress uses layoutz

- **WHEN** indicators are enabled for package work
- **THEN** the progress presentation is produced via layoutz primitives and hosted by a layoutz inline or application runtime for panel redraw

#### Scenario: Panel host is not a project-owned multi-line ANSI writer

- **WHEN** a multi-progress or sequential step-bar panel is active
- **THEN** advancing and clearing that panel’s multi-line region is performed through the layoutz panel host rather than a separate project-maintained move-up/line-count redraw loop

#### Scenario: Product contracts preserved under layoutz host

- **WHEN** indicators are enabled under the layoutz-hosted panels
- **THEN** indicators still write only to stderr (not machine stdout), logs remain deferred until panel clear, and successful package rows still disappear while failed rows remain until phase clear as specified by multi-progress requirements
