## ADDED Requirements

### Requirement: In-place multi-line panel redraw

When activity indicators are enabled, multi-progress and sequential step-bar panels SHALL redraw in place on standard error. As the panel’s logical height grows or shrinks between frames (including when successful package rows are removed and failed rows remain), the program SHALL NOT leave prior indicator frames as permanent ghost lines above the live panel. After each redraw, the owned panel band SHALL match the current frame’s logical line count so that a subsequent redraw or full panel clear removes exactly that band and no residual indicator lines remain in the scrollback from intermediate frames of the same panel session.

#### Scenario: Shrinking multi-progress does not stack top bars

- **WHEN** the user runs `outdated` with indicators enabled and concurrent package jobs complete over time so that package rows disappear and the top-level done/total advances
- **THEN** the top-level progress bar updates in place without leaving a trail of previous `done/total` indicator lines stacked above the live panel

#### Scenario: Panel clear removes the full live band

- **WHEN** a multi-progress or step-bar panel ends (phase complete, pause for interactive UI, or teardown)
- **THEN** the program clears the entire owned panel band so that deferred logs and machine stdout are not preceded by leftover intermediate indicator frames from that panel session

#### Scenario: Growing then shrinking panel stays aligned

- **WHEN** indicators are enabled and the number of in-flight package rows increases and later decreases within one multi-progress phase
- **THEN** each redraw replaces the previous panel content in place and intermediate frames do not accumulate as permanent stderr lines
