## ADDED Requirements

### Requirement: Outdated consumer line indicates overlay provider block

When `outdated` checks a `DepsAndAssets` package that has an overlay wait-edge provider as specified by `overlay-apply-waves`, the program SHALL evaluate plan-delta using the same hypothetical overlay ceilings and provider latest-fetch rules as `update` refuse (including check-cache for the provider’s latest payload when valid). When plan-delta holds, the program SHALL still emit the consumer’s runtime-lane stdout line(s) for the **on-disk** ceiling plan when those lines would otherwise be emitted, **or** emit a single consumer line for the hypothetical higher target when the on-disk plan has no gap, and that line SHALL **indicate** that the consumer is blocked on the overlay provider (the provider package key SHALL appear in the indication). The program SHALL NOT present the consumer as fully current (no stdout) when plan-delta holds. When the provider is in the `outdated` check set and is itself GitMv-outdated, that provider SHALL still produce its own unlabeled latest line. When the provider is not in the check set, the consumer line SHALL still indicate the block; the program SHALL still latest-check the provider for plan-delta. Provider latest-fetch failure SHALL NOT omit the consumer as current: the consumer SHALL hard-fail that package check or emit an error-class report that names the provider (**fail-closed**), matching `overlay-apply-waves` fail-closed policy, and SHALL NOT print an ordinary up-to-date omission for that consumer.

#### Scenario: Ralph line indicates blocked on bun-bin

- **WHEN** on-disk bun-bin ceilings keep ralph-tui at a PV already present, bun-bin remote latest would raise the ceiling, and ralph-tui would select a newer PV under hypothetical ceilings
- **THEN** stdout includes a ralph-tui line that indicates blocked on `dev-lang/bun-bin`
- **AND** the program does not treat ralph-tui as having no outdated output solely because the on-disk plan matches local ebuilds

#### Scenario: Bun-bin still has its own outdated line when checked

- **WHEN** `outdated` includes both `dev-lang/bun-bin` and `dev-util/ralph-tui` and bun-bin is GitMv-outdated with ralph plan-delta
- **THEN** stdout includes bun-bin’s unlabeled `LOCAL -> REMOTE` line
- **AND** ralph-tui’s line indicates the bun-bin block
