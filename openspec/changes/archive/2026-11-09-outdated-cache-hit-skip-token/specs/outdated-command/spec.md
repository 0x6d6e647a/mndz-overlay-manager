# Spec Delta

## MODIFIED Requirements

### Requirement: Outdated GitHub live-fetch sequencing

When `outdated` will perform live `api.github.com` work as specified by `github-api-resilience` and `github-auth`, it SHALL resolve or decrypt the GitHub token, run the GitHub health preflight, then run per-package checks. When this run will not call `api.github.com`, `outdated` SHALL skip that token decrypt and health preflight. A valid check-cache hit is not a live read, including when the cached plan still needs work. A miss, `--refresh`, an uncached overlay-provider latest, or an uncached hypothetical consumer plan is a live read. One live read in the selection makes the run live. GitHub rate-limit class, token-rejected, remaining-zero, and required Statuspage component outage failures SHALL abort the command as spine hard failures (error log, exit status `1`) rather than per-package soft fetch warnings.

#### Scenario: Live outdated prompts then health then checks

- **WHEN** `outdated` has a cache miss on a GitHub-source package, no env token, and a config envelope
- **THEN** the program prompts for the wrap password
- **AND** then runs the GitHub health preflight
- **AND** then performs package checks using the decrypted token

#### Scenario: Needs-work plan hit skips decrypt

- **WHEN** `outdated` is run without `--refresh`, no env token, and a config envelope, and every selected GitHub read is a valid check-cache hit, including a deps plan whose plan still needs work
- **THEN** the program does not prompt for the wrap password
- **AND** it does not call `api.github.com` for that run

#### Scenario: One miss prompts for the selection

- **WHEN** `outdated` selects several packages, no env token, and a config envelope, and one selected GitHub-source package has no valid check-cache hit while the others do
- **THEN** the program prompts for the wrap password once before package checks

#### Scenario: Cold provider latest prompts

- **WHEN** `outdated` selects a DepsAndAssets consumer whose deps plan is a valid check-cache hit, and the overlay-provider latest read is not a valid hit
- **THEN** the program prompts for the wrap password
- **AND** the provider latest read uses the decrypted token

#### Scenario: Changed ceilings prompt

- **WHEN** `outdated` selects a DepsAndAssets consumer whose deps plan and overlay-provider latest are valid check-cache hits, and replacing the provider's newest on-disk PV with that latest changes overlay ceilings so the hypothetical consumer plan will run
- **THEN** the program prompts for the wrap password
- **AND** that hypothetical plan uses the decrypted token

#### Scenario: Unchanged ceilings skip decrypt

- **WHEN** `outdated` selects a DepsAndAssets consumer whose deps plan and overlay-provider latest are valid check-cache hits, and those ceilings are unchanged
- **THEN** the program does not prompt for the wrap password
- **AND** it does not re-list that consumer's upstream versions for plan-delta

#### Scenario: Refresh prompts

- **WHEN** the operator runs `outdated --refresh` for a GitHub-source package, no env token, and a config envelope, and a valid check-cache hit exists
- **THEN** the program prompts for the wrap password before the live read

#### Scenario: Rate-limit during outdated is spine failure

- **WHEN** an `api.github.com` rate-limit class or 401 failure occurs during `outdated`
- **THEN** the program logs an error and exits with status `1`
