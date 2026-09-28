# Spec Delta

## MODIFIED Requirements

### Requirement: README documents overlay apply order and blocked-on

When overlay wait-edges affect `update` and `outdated` operator-visible behavior, `README.md` SHALL document at operator depth:

1. Untargeted `update` plans Bun consumers against the selected bun-bin remote when bun-bin needs work, and applies those consumers after bun-bin’s signed overlay commit without a disk re-plan.
2. `outdated`, when the ceiling provider is in the check set and GitMv-outdated and the consumer plan would change, prints the consumer versions that untargeted `update` would apply, and does not describe those lines as blocked on the provider. When that provider is left out of the check and the plan would change, `outdated` prints those versions and one `category/package:` line with the same refuse text `update` uses. A hypothetical plan with no version gap and nothing to delete prints no consumer line. `outdated` still exits successfully.
3. `update` of only the consumer while that overlay provider is stale and plan-delta holds (or the provider latest cannot be fetched) hard-fails the consumer and names the provider; it does not silently apply under the old ceiling or pull the provider into the selection.
4. `outdated` prints `PV -> removed` for a `DepsAndAssets` version that `update` of that package alone would delete, and does not print that line when another on-disk ebuild still requires the version.

#### Scenario: Operator finds same-run bun-bin then ralph in README

- **WHEN** an operator reads `README.md` `update` documentation
- **THEN** the text describes overlay runtime apply order and refuse-when-provider-omitted without requiring OpenSpec as the primary path

#### Scenario: Operator finds the outdated preview in README

- **WHEN** an operator reads `README.md` `outdated` documentation
- **THEN** the text describes the hypothetical-plan preview when bun-bin is included and GitMv-outdated
- **AND** the text describes the refuse line when bun-bin is left out
- **AND** the text describes `PV -> removed` lines
