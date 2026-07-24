## MODIFIED Requirements

### Requirement: Lane labels

Go tree-lane user-visible lines SHALL use labels of the form `(dev-lang/go <arch>)` or `(dev-lang/go ~<arch>)` for each plain or tilde lane that participates in planning, where `<arch>` is an architecture discovered from gentoo `dev-lang/go` KEYWORDS (not limited to a closed set of only `amd64` and `arm64`). When only amd64 and arm64 lanes exist, labels SHALL include the corresponding `(dev-lang/go amd64)`, `(dev-lang/go ~amd64)`, `(dev-lang/go arm64)`, and `(dev-lang/go ~arm64)` forms as applicable. Shared multi-ecosystem label rules are defined by `runtime-lanes`; this requirement specializes the Go runtime package atom `dev-lang/go`.

#### Scenario: Label tokens for amd64 tilde

- **WHEN** a report line is emitted for the amd64 tilde lane
- **THEN** the line includes the substring `(dev-lang/go ~amd64)`

#### Scenario: Non-amd64-arm64 arch label

- **WHEN** planning includes a Go lane for an arch other than amd64 and arm64 (for example loong)
- **THEN** user-visible lines for that lane use `(dev-lang/go loong)` or `(dev-lang/go ~loong)` as appropriate to the tier
