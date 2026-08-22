## ADDED Requirements

### Requirement: Overlay ceilings rediscovered after provider commit

When `update` re-plans a `DepsAndAssets` consumer after its overlay ceiling-provider package has a successful signed overlay commit in the same run, as specified by `overlay-apply-waves`, ceiling discovery for that ecosystem SHALL read the committed overlay provider package directory (non-live ebuilds) at re-plan time. The program SHALL NOT reuse a start-of-run overlay ceiling snapshot for that re-plan. Gentoo-sourced ceilings (Go, Npm, Cargo, Sbcl) are unchanged by overlay GitMv and SHALL NOT require mid-run rediscovery solely because an overlay Bun provider committed.

#### Scenario: Bun re-plan sees new overlay ebuild

- **WHEN** `dev-lang/bun-bin` is committed from PV `1.2.0` to `1.3.0` in the same `update` and `dev-util/ralph-tui` is then re-planned
- **THEN** ralph-tui Bun lane ceilings include `1.3.0` from the overlay bun-bin directory
- **AND** the re-plan does not keep the start-of-run `1.2.0` ceiling solely because ceilings were already discovered earlier in the process
