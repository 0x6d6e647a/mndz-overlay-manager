## ADDED Requirements

### Requirement: Newest-first go.mod probing with early exit

When resolving `go` directives for Go tree-lane planning, the library SHALL consider comparable upstream package versions in newest-first PV order (the order produced by the list-comparable versions capability). For each version in that order, the library SHALL fetch and parse `go.mod` (honoring the configured subdirectory) subject to the process work budget. After each parseable `go_req`, the library SHALL use that version as a candidate for lane selection. The library SHALL stop fetching further older versions once every lane that has a Go ceiling has a target package PV equal to the maximum version among probed candidates with `go_req ≤` that lane’s ceiling, or when the version list is exhausted. Tags with missing or unparseable `go` directives SHALL be skipped (no candidate). Lane targets produced by early-exit probing SHALL match the targets produced by probing every listed version and then applying the same max-under-ceiling selection rules. Lanes without a ceiling SHALL remain without a target. Probes for a single package plan SHALL proceed one version at a time (sequential), each gated by the work budget; unbounded concurrent probing of all tags for one plan is not required.

#### Scenario: Tip fills all ceilinged lanes

- **WHEN** the newest comparable version has a parseable `go_req` that is ≤ every lane’s Go ceiling
- **THEN** planning does not fetch `go.mod` for older versions after that tip probe, and every ceilinged lane targets that tip PV

#### Scenario: Plain needs an older PV than tilde

- **WHEN** a newer version’s `go_req` exceeds the plain ceiling but not the tilde ceiling, and an older version’s `go_req` is ≤ the plain ceiling
- **THEN** the tilde lane targets the newer version, the plain lane targets that older version, and versions older than the plain target are not probed once all ceilinged lanes are filled

#### Scenario: Early-exit targets match full probe

- **WHEN** the same ceilings and the same `go.mod` contents per tag are available
- **THEN** early-exit newest-first probing yields the same lane target PVs as probing every listed version and then selecting max-under-ceiling per lane

#### Scenario: Unparseable tip is skipped

- **WHEN** the newest version has no parseable `go` directive and an older version does
- **THEN** planning continues to older versions until lanes are filled or the list ends

## MODIFIED Requirements

### Requirement: Concurrent go.mod version probes under work budget

When building version candidates for Go tree-lane planning (resolving `go` directives across upstream tags), each go.mod fetch SHALL be gated by the process work budget. Probe work SHALL NOT be unbounded relative to that budget. For a single package plan, go.mod probes SHALL run sequentially in newest-first order with early exit as specified in the newest-first early-exit requirement. Functional lane selection results SHALL match full-list probing: same ceilings and same go.mod contents per tag yield the same lane targets.

#### Scenario: Probe gated by work budget

- **WHEN** planning probes go.mod for upstream versions and the work budget is active
- **THEN** each go.mod fetch for that plan acquires a work slot and does not exceed the work budget

#### Scenario: Lane selection unchanged by probe strategy

- **WHEN** the same ceilings and the same go.mod contents per tag are available
- **THEN** sequential newest-first early-exit probing produces the same lane targets as probing every listed version would

### Requirement: Planning progress callbacks

Go tree-lane planning used by `outdated` checks and by `update` apply planning SHALL be able to report progress to the caller for three coarse phases: when ceiling discovery starts and completes, when version listing starts and completes, and when go.mod probing (the full early-exit walk) starts and completes as a single phase. Callers that do not supply progress hooks SHALL still obtain correct plans. The caller SHALL NOT be required to treat each individual tag probe as a separate progress step.

#### Scenario: Step total uses coarse phases

- **WHEN** planning runs with progress hooks supplied
- **THEN** the caller is informed of a step total that accounts for ceiling discovery, version listing, and one step for the entire go.mod probe walk (three steps, or an equivalent monotone coarse scheme over those phases)

#### Scenario: Hooks optional

- **WHEN** planning runs without progress hooks
- **THEN** planning still returns a correct plan or error and does not require a progress UI
