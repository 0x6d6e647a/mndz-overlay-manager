## ADDED Requirements

### Requirement: Outdated GitHub live-fetch sequencing

When `outdated` will perform live `api.github.com` work as specified by `github-api-resilience` and `github-auth`, it SHALL resolve or decrypt the GitHub token, run the GitHub health preflight, then run per-package checks. When every selected GitHub-source package has a valid check-cache hit and `--refresh` was not passed, `outdated` SHALL skip that token decrypt and health preflight. GitHub rate-limit class, token-rejected, remaining-zero, and required Statuspage component outage failures SHALL abort the command as spine hard failures (error log, exit status `1`) rather than per-package soft fetch warnings.

#### Scenario: Live outdated prompts then health then checks

- **WHEN** `outdated` has a cache miss on a GitHub-source package, no env token, and a config envelope
- **THEN** the program prompts for the wrap password
- **AND** then runs the GitHub health preflight
- **AND** then performs package checks using the decrypted token

#### Scenario: Rate-limit during outdated is spine failure

- **WHEN** an `api.github.com` rate-limit class or 401 failure occurs during `outdated`
- **THEN** the program logs an error and exits with status `1`

### Requirement: Outdated emits completed reports before GitHub abort

When `outdated` aborts because of a GitHub rate-limit class, token-rejected, or health hard failure after some package checks have finished, the program SHALL still emit those completed packages’ stdout outdated lines and their non-GitHub-abort soft-warning log lines after the check progress panel is cleared (when indicators were shown), then log the command error and exit `1`. Packages not yet started SHALL NOT be reported as per-package fetch errors solely because the latch tripped.

#### Scenario: Partial outdated lines then error

- **WHEN** two GitHub packages have already produced outdated lines and a later package hits an `api.github.com` rate-limit 403
- **THEN** those two stdout lines are written
- **AND** the program logs the rate-limit error
- **AND** it exits with status `1`

## MODIFIED Requirements

### Requirement: Soft warnings on stderr

The program SHALL log a warning (default log level includes warnings) for each package that is unconfigured (no source), fails fetch or remote version parse for a reason other than an `api.github.com` rate-limit class or HTTP 401 failure specified by `github-api-resilience`, or is ahead of upstream (local PV greater than remote). Soft outcomes SHALL NOT cause a non-zero exit by themselves. GitHub rate-limit class, token-rejected, remaining-zero, and required Statuspage outage failures SHALL follow `github-api-resilience` (command error, exit `1`) instead of this soft-warning path.

#### Scenario: Unconfigured package

- **WHEN** a package has no hardcoded update source in the policy map
- **THEN** the program logs a warning naming that `category/package` and continues

#### Scenario: Ahead of upstream

- **WHEN** local PV is greater than remote PV for a package
- **THEN** the program logs a warning for that package and does not write an outdated stdout line for it

#### Scenario: Fetch failure

- **WHEN** upstream fetch fails for a package for a reason other than `api.github.com` rate-limit class or HTTP 401
- **THEN** the program logs a warning describing the failure and continues checking remaining packages

### Requirement: Exit zero on successful check

When the spine succeeds and the per-package check loop completes without a GitHub health, rate-limit class, or token-rejected hard failure, the program SHALL exit with status `0` even if some packages are outdated, unconfigured, ahead, or soft-failed.

#### Scenario: Outdated packages still exit zero

- **WHEN** at least one package is outdated and no hard spine error occurred
- **THEN** the program exits with status `0`

#### Scenario: All current exits zero with empty stdout

- **WHEN** every configured package is up to date and there are no soft-failure warnings required beyond silence for ok packages
- **THEN** the program exits with status `0` and stdout has no outdated lines
