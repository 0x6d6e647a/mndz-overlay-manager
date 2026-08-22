## ADDED Requirements

### Requirement: README documents overlay apply order and blocked-on

When overlay wait-edges affect `update` and `outdated` operator-visible behavior, `README.md` SHALL document at operator depth:

1. Untargeted `update` applies overlay runtime providers (for example `dev-lang/bun-bin`) before their Bun consumers in the same run after the provider’s signed overlay commit, then re-plans those consumers.
2. `outdated` consumer output indicates when a `DepsAndAssets` package is blocked on a newer overlay ceiling provider rather than appearing fully current under the on-disk ceiling.
3. `update` of only the consumer while that overlay provider is stale and plan-delta holds (or the provider latest cannot be fetched) hard-fails the consumer and names the provider; it does not silently apply under the old ceiling or pull the provider into the selection.

#### Scenario: Operator finds same-run bun-bin then ralph in README

- **WHEN** an operator reads `README.md` `update` documentation
- **THEN** the text describes overlay runtime apply order and refuse-when-provider-omitted without requiring OpenSpec as the primary path
