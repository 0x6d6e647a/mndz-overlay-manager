# outdated-command Specification

## Purpose

Define the `outdated` subcommand: spine, package targets, per-package newest-local checks against update sources, soft warnings, exit status, and progress presentation.

## Requirements

### Requirement: Outdated subcommand spine

The CLI SHALL provide an `outdated` subcommand that, like `list`, loads configuration, resolves the overlay path (config then optional `--overlay-path`), validates the overlay, and discovers ebuilds before performing update checks. Hard failures on that spine SHALL log an error and exit with status `1`. Empty inventory SHALL be treated as an error with exit status `1`.

#### Scenario: Successful spine with packages

- **WHEN** the user runs `outdated` against a valid overlay containing ebuilds
- **THEN** the program loads config, validates the overlay, discovers ebuilds, and proceeds to per-package checks

#### Scenario: Empty inventory

- **WHEN** the user runs `outdated` against a valid overlay with zero ebuilds
- **THEN** the program logs an error and exits with status `1`

### Requirement: Per-package newest local version

For each `category/package` with one or more ebuilds, the check SHALL use the newest local version by PV ordering as the local side of the comparison. Source resolution SHALL use the hardcoded package policy only (no ebuild text inference).

#### Scenario: Multiple ebuild versions

- **WHEN** a package directory contains ebuilds for `9.4.5` and `9.6.1`
- **THEN** the local version used for the update check is `9.6.1`

#### Scenario: Source from hardcoded policy

- **WHEN** a package has a hardcoded update source in the policy map
- **THEN** the outdated check uses that source without reading the ebuild for inference

### Requirement: Unconfigured when absent from policy map

When a package has no hardcoded policy (or no source), the outdated check SHALL treat it as unconfigured and log a warning, continuing with other packages, matching the existing soft-warning behavior for unconfigured packages.

#### Scenario: Package missing from map

- **WHEN** a discovered package is not present in the hardcoded policy map
- **THEN** the program logs a warning that no update source is configured for that package and does not print an outdated stdout line for it

### Requirement: Outdated stdout format

For each non-`DepsAndAssets` package whose local PV is strictly less than the fetched remote PV, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, where `LOCAL` and `REMOTE` are pretty-rendered ebuild versions in PV form (no leading `v`, optional `-rN` on local when present). For `DepsAndAssets` packages, stdout lines SHALL follow the runtime-lane outdated reporting requirement (possibly multiple lines and lane labels) instead of a single latest-only comparison. Packages that are up to date under their applicable rules SHALL NOT produce a stdout line.

#### Scenario: GitMv outdated single line

- **WHEN** a GitMv package is outdated from `1.0` to `1.1`
- **THEN** stdout contains one unlabeled `LOCAL -> REMOTE` line

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `DepsAndAssets`, the `outdated` check SHALL use the runtime-lane planner for that ecosystem (runtime package ceilings, candidate set, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not satisfied by the canonical highest-revision non-live same-PV ebuild with adequate content for that tip, the program SHALL write a stdout line of the form `category/package FROM -> TO (...)` using the lane label from `runtime-lanes` (for example `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, `(dev-lang/bun-bin ~arm64)`, or `(dev-lang/rust|rust-bin ~amd64)`). Adequacy SHALL include parameterized asset URI as defined by `deps-assets` (package-owned mndz-overlay-assets release tags only), planned KEYWORDS, the ecosystem runtime comparison, and an exact Manifest `DIST` record for every required primary and companion basename.

Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `FROM`; when multiple locals converge to one target, emit one line per local `FROM` to that `TO`. Versions SHALL use PV pretty form without a leading `v`.

For Cargo, `RUST_MIN_VER` adequacy SHALL use the decision floor from `cargo-crates-assets`: the maximum of the planned tag-floor snapshot and the canonical highest-revision same-PV ebuild's valid `RUST_MIN_VER`. A valid written floor at or above that decision floor SHALL be adequate; a lower, missing, or malformed written floor SHALL need work. If neither decision-floor operand is usable, the PV SHALL be reported as needing work and marked for full-path materialization rather than treated as adequate. Incomplete Cargo tag-floor coverage SHALL NOT be reported as a `0.0.0` requirement; such a candidate SHALL NOT appear as a lane `TO` solely because discovery failed to complete.

A gap line MAY include ` [assets reusable]` only when the PV is not forced full and a release lookup confirms that every required primary and companion asset is usable. If release completeness cannot be established because lookup dependencies are unavailable or lookup fails, `outdated` SHALL still report the needs-work line but SHALL conservatively omit the optional marker. A primary-only or otherwise partial release SHALL NOT receive that marker. The marker rule applies to missing-PV and same-PV content gaps alike.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` with other lanes satisfied or absent
- **THEN** stdout includes both transitions with their corresponding lane labels

#### Scenario: Npm package lane line

- **WHEN** `dev-util/openspec` has a runtime-lane gap for nodejs
- **THEN** stdout includes a labeled line naming the nodejs runtime lane rather than a single unlabeled latest-only comparison

#### Scenario: Bun package lane line

- **WHEN** `dev-util/ralph-tui` has a runtime-lane gap for bun-bin
- **THEN** stdout includes a labeled line naming the bun-bin runtime lane

#### Scenario: Cargo package lane line

- **WHEN** `dev-util/mise` has a runtime-lane gap for the rust toolchain union
- **THEN** stdout includes a labeled line naming `dev-lang/rust|rust-bin` or equivalent rather than remaining soft-skipped as Unsupported

#### Scenario: Cargo ebuild matching the written floor is not flagged

- **WHEN** `dev-util/usage` was written with `RUST_MIN_VER="1.95.0"`, its planned tag floor is `1.91.0`, and its canonical same-PV donor is the same written `1.95.0`
- **WHEN** `outdated` checks the same PV
- **THEN** it does not print a `6.4.1 -> 6.4.1` content-only line

#### Scenario: Highest revision controls outdated adequacy

- **WHEN** bare, `-r2`, and `-r10` ebuilds exist for one planned PV with different content
- **THEN** `outdated` assesses `-r10` regardless of discovery order and ignores a live `9999` ebuild as a donor

#### Scenario: Missing direct Cargo floor is reported as full-path work

- **WHEN** a present Cargo PV has neither a planned tag floor nor a valid floor in its canonical same-PV ebuild
- **THEN** `outdated` reports the lane gap and does not label it `[assets reusable]` even if release assets exist

#### Scenario: Incomplete Cargo candidate is not a zero-floor gap

- **WHEN** the newest upstream Cargo tag is incomplete and an older complete tag remains at or below the rust ceiling
- **THEN** `outdated` does not treat the incomplete newest tag as requirement `0.0.0`

#### Scenario: Missing companion distfile is flagged

- **WHEN** a package's canonical ebuild and primary Manifest record are adequate but an exact Manifest record for a required companion such as opencode models is absent
- **THEN** the package is reported as needing work
- **AND** `[assets reusable]` appears only if every required primary and companion release asset is usable

#### Scenario: Release lookup failure suppresses optional marker

- **WHEN** a needs-work line is known but release completeness lookup fails
- **THEN** `outdated` still emits the line and omits `[assets reusable]` rather than claiming unproven reuse

#### Scenario: Missing PV with complete release may be reusable

- **WHEN** a planned PV is absent locally, is not forced full, and release lookup confirms every required asset
- **THEN** its lane gap may include `[assets reusable]`

#### Scenario: Companion sidecar is not the required distfile

- **WHEN** the only matching-looking Manifest record adds a suffix such as `.asc` to the required companion basename
- **THEN** `outdated` treats the exact companion record as missing

#### Scenario: Codex pin-keyed rusty-v8 URL is not a same-PV gap

- **WHEN** `dev-util/codex` has a non-live ebuild at planned PV `0.153.4` with adequate KEYWORDS, `RUST_MIN_VER`, empty `CRATES`, parameterized `codex-${PV}` crates URL, Manifest DIST for the crates tarball, and a rusty-v8 assets URL under tag `rusty-v8-${RUSTY_V8_VER}`
- **WHEN** both rust lanes select that PV
- **THEN** `outdated` does not print `0.153.4 -> 0.153.4` content-only lines for those lanes

### Requirement: Non-Go outdated unchanged

Packages that are not `DepsAndAssets` SHALL continue to use newest-local vs single fetched latest comparison and the single-line `category/package LOCAL -> REMOTE` format (PV form, no leading `v`) without runtime-lane labels.

#### Scenario: Binary package format

- **WHEN** `dev-util/grok-build-bin` is outdated
- **THEN** stdout uses a single unlabeled line

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

### Requirement: Outdated package targets

The `outdated` subcommand SHALL accept zero or more package targets and MAY accept the subcommand-local flag `--refresh` (see outdated refresh requirement). It SHALL NOT accept other subcommand-local flags beyond `--refresh`. Each target SHALL be either a full key `category/package` or a package name `package` that is unambiguous among discovered packages. With zero targets, the program SHALL check every package key present in the discovered inventory. With one or more targets, the program SHALL resolve tokens with the same rules as `update` and `gencache` (shared target resolution): unknown package tokens and ambiguous bare package names SHALL be hard failures that abort the command before per-package checks (exit status `1`). After successful resolution, the program SHALL run outdated checks only for the selected package keys; packages not in the selection SHALL produce neither stdout outdated lines nor soft-warning outcomes for this run. Version or PV values SHALL NOT be accepted as CLI arguments. Global options such as `--config`, `--overlay-path`, `--jobs`, and log verbosity still apply.

#### Scenario: Zero targets checks full inventory

- **WHEN** the user runs `outdated` with only top-level flags such as `--config` or `--overlay-path` and no package arguments
- **THEN** the program checks every discovered package

#### Scenario: Category package target

- **WHEN** the user runs `outdated dev-util/crush` against an inventory that contains that package
- **THEN** the program checks only `dev-util/crush` and does not emit outdated lines or soft warnings for other packages solely because they were not selected

#### Scenario: Bare package name

- **WHEN** the user runs `outdated crush` and exactly one discovered package has package name `crush`
- **THEN** the program checks that package key

#### Scenario: Ambiguous bare name hard-fails

- **WHEN** the user runs `outdated foo` and two categories both contain package name `foo`
- **THEN** the program logs an error describing the ambiguity and exits with status `1` without running the check loop

#### Scenario: Unknown package hard-fails

- **WHEN** the user runs `outdated missing/pkg` and that key is not in the inventory
- **THEN** the program logs an error and exits with status `1` without running the check loop

#### Scenario: Refresh with targets

- **WHEN** the user runs `outdated --refresh dev-util/crush`
- **THEN** the program resolves the target and forces live check work for that package only

### Requirement: Concurrent outdated checks

The `outdated` per-package check loop SHALL run package checks concurrently, subject to the global jobs limit. Functional outcomes (stdout outdated lines, soft warnings, exit status) SHALL remain equivalent to sequential checking aside from wall-clock timing and indicator presentation.

#### Scenario: Multiple packages checked under concurrency

- **WHEN** the user runs `outdated` against an overlay with multiple discovered packages
- **THEN** the program may check packages concurrently and still emits correct outdated stdout lines and soft warnings for each package

### Requirement: Outdated multi-progress when enabled

When activity indicators are enabled, `outdated` SHALL present multi-progress for the check phase (top-level done/total bar and per-package spinner rows as specified by `cli-activity`). Go or other technique sub-phases do not apply to checks; rows MAY show a short status such as fetching when useful.

#### Scenario: TTY outdated shows multi-progress

- **WHEN** the user runs `outdated` with indicators enabled
- **THEN** a multi-progress panel is shown during package checks and is cleared before deferred report output

### Requirement: Deferred outdated report emission

When activity indicators were shown for the check phase, the program SHALL emit `outdated` stdout lines and soft-warning log lines only after the check multi-progress panel is cleared. When indicators are disabled, emission timing MAY remain immediate after each report is known or after the batch completes, but stdout format and warning semantics SHALL be unchanged.

#### Scenario: Stdout lines appear after panel clear

- **WHEN** indicators are enabled and at least one package is outdated
- **THEN** the `category/package LOCAL -> REMOTE` lines are written to stdout only after the check progress panel has been cleared

### Requirement: Outdated uses check cache

The `outdated` command SHALL load and consult the shared check cache for selected packages when the cache is enabled and `--refresh` was not passed. On a valid hit, the command SHALL derive check outcomes from the cached remote PV or runtime-lane plan (with content-fix still computed from disk) without repeating upstream latest fetch or deps plan network work for that package. After successful live checks, the command SHALL store eligible entries when the cache is enabled. The command SHALL emit the check-cache hit/fetch info summary as specified by `check-cache`.

#### Scenario: Second outdated within TTL hits cache

- **WHEN** the user runs `outdated` successfully and then runs `outdated` again within the effective TTL without `--refresh` and without local fingerprint changes
- **THEN** configured packages with stored entries may complete without repeating their upstream check network work

#### Scenario: Outdated stores after live check

- **WHEN** the user runs `outdated --refresh` (or a cold cache) and a package check succeeds
- **THEN** an eligible cache entry for that package is written when the cache is enabled

### Requirement: Outdated refresh flag

The `outdated` subcommand SHALL accept a `--refresh` flag that forces live upstream check or plan work for all selected packages, ignoring existing cache entries for reads, and SHALL write fresh eligible entries when the cache is enabled.

#### Scenario: Refresh ignores existing entries

- **WHEN** the user runs `outdated --refresh` while valid cache entries exist for selected packages
- **THEN** the program performs live check or plan work for those packages rather than using the existing entries for reads

### Requirement: Outdated consumer line indicates overlay provider block

When `outdated` checks a `DepsAndAssets` package that has an overlay wait-edge provider as specified by `overlay-apply-waves`, the program SHALL evaluate plan-delta using the same hypothetical overlay ceilings and provider latest-fetch rules as `update` refuse (including check-cache for the provider's latest payload when valid). After a successful provider latest-fetch, the program SHALL compute hypothetical overlay ceilings and compare them to on-disk overlay ceilings from the same provider package. When the two ceiling results are equal, plan-delta does not hold. In that case the program SHALL NOT re-list upstream package versions or re-probe per-PV upstream metadata solely to evaluate plan-delta, and SHALL NOT print a provider-refuse line for the consumer. When the two ceiling results differ, the program SHALL evaluate plan-delta by planning the consumer against the hypothetical ceilings as already specified for `update` refuse. The program SHALL NOT store that hypothetical plan as a check-cache deps payload, as specified by `check-cache`.

The provider is in the `outdated` check set when the resolved selection contains that provider package key (including an untargeted `outdated`, which checks every discovered package). The provider is GitMv-outdated when the fetched remote latest is strictly greater than the newest non-live on-disk provider PV. That comparison SHALL use this provider latest fetch and SHALL NOT wait on the provider package's own outdated result.

When the provider is in the check set and GitMv-outdated and plan-delta holds, the program SHALL emit the consumer's runtime-lane gap lines for the hypothetical working plan, using the same lane-line rules as an on-disk gap (including `[assets reusable]` only when that plan's PV qualifies). The program SHALL NOT emit the on-disk plan's gap lines in their place, and SHALL NOT collapse several hypothetical lane gaps into one line that names only the highest PV. The program SHALL NOT append a provider-refuse line. When that hypothetical plan has no runtime-lane gap lines and ebuild-removal reporting has no removal lines, the program SHALL print no stdout line for the consumer.

When the provider is not in the check set and plan-delta holds, the program SHALL emit those same hypothetical gap lines, then exactly one further stdout line of the form `category/package: <refuse message>`, where `<refuse message>` is the unselected-provider refuse message specified by `overlay-apply-waves` (it names the provider and tells the operator to update that provider or run untargeted `update`). That refuse line SHALL be the consumer's only stdout line when the hypothetical plan has no gap lines and no removal lines. Consumer stdout for this check SHALL NOT contain the words "blocked on". The refuse line SHALL NOT by itself make `outdated` exit non-zero.

When the provider is in the check set and is not GitMv-outdated, the program SHALL emit the on-disk plan's gap lines and SHALL NOT print a provider-refuse line, including when the fetched remote latest is older than the on-disk provider PV.

When the provider is in the check set and is itself GitMv-outdated, that provider SHALL still produce its own unlabeled `LOCAL -> REMOTE` line. When the provider is not in the check set, the program SHALL still latest-check the provider for plan-delta. Provider latest-fetch failure SHALL NOT omit the consumer as current: the consumer SHALL hard-fail that package check or emit an error-class report that names the provider (fail-closed), matching `overlay-apply-waves` fail-closed policy, and SHALL NOT print an ordinary up-to-date omission for that consumer.

`outdated` SHALL NOT create an overlay git commit and SHALL NOT start a materialize-image build while producing these lines.

#### Scenario: Selected bun-bin prints the hypothetical ralph lines

- **WHEN** `outdated` includes `dev-lang/bun-bin` and `dev-util/ralph-tui`, bun-bin's remote latest is strictly greater than the on-disk bun-bin PV, on-disk ceilings would keep ralph-tui at an installed PV, and hypothetical ceilings would select a newer ralph-tui PV on one or more lanes
- **THEN** stdout includes a ralph-tui lane line for each such hypothetical gap, naming the bun-bin lane
- **AND** those lines do not contain "blocked on"
- **AND** stdout does not contain a `dev-util/ralph-tui:` refuse line
- **AND** stdout does not contain the on-disk plan's gap in place of the hypothetical gap

#### Scenario: Several hypothetical lanes stay several lines

- **WHEN** `outdated` includes bun-bin and ralph-tui, bun-bin is GitMv-outdated, and the hypothetical plan has two unsatisfied lanes with different target PVs
- **THEN** stdout includes two ralph-tui lane lines, one per lane
- **AND** stdout does not replace them with a single line whose only label is a provider block

#### Scenario: Satisfied hypothetical plan prints nothing for the consumer

- **WHEN** `outdated` includes bun-bin and ralph-tui, bun-bin is GitMv-outdated, plan-delta holds because the on-disk plan needs work, and the hypothetical plan has no lane gap and would delete no ebuild
- **THEN** stdout has no ralph-tui line
- **AND** bun-bin still prints its unlabeled `LOCAL -> REMOTE` line when bun-bin itself is GitMv-outdated

#### Scenario: Bun-bin still has its own outdated line when checked

- **WHEN** `outdated` includes both `dev-lang/bun-bin` and `dev-util/ralph-tui` and bun-bin is GitMv-outdated with ralph plan-delta
- **THEN** stdout includes bun-bin's unlabeled `LOCAL -> REMOTE` line
- **AND** ralph-tui's lines do not contain "blocked on"

#### Scenario: Left-out bun-bin prints hypothetical lines and one refuse line

- **WHEN** `outdated` checks `dev-util/ralph-tui`, bun-bin is not in the check set, bun-bin's remote latest would change the ceilings, and the hypothetical plan selects a newer ralph-tui PV
- **THEN** stdout includes the hypothetical ralph-tui lane line
- **AND** stdout includes exactly one line that starts with `dev-util/ralph-tui:` and is the unselected-provider refuse message for `dev-lang/bun-bin`, including recovery by updating that provider or running untargeted `update`
- **AND** the command exits `0` when no spine hard failure occurred

#### Scenario: Left-out plan-delta with nothing to print still refuses

- **WHEN** `outdated` checks `dev-util/ralph-tui`, bun-bin is not in the check set, plan-delta holds, and the hypothetical plan has no lane gap and would delete no ebuild
- **THEN** stdout for ralph-tui is only the `dev-util/ralph-tui:` refuse line naming `dev-lang/bun-bin`
- **AND** the program does not omit ralph-tui as current

#### Scenario: Provider already current uses on-disk lines

- **WHEN** `outdated` includes bun-bin and ralph-tui and bun-bin's remote latest is not strictly greater than the on-disk bun-bin PV
- **THEN** ralph-tui stdout follows the on-disk plan
- **AND** stdout does not contain a `dev-util/ralph-tui:` refuse line

#### Scenario: Ralph line indicates blocked on bun-bin

- **WHEN** `outdated` checks `dev-util/ralph-tui` without `dev-lang/bun-bin` in the check set, on-disk bun-bin ceilings keep ralph-tui at a PV already present, bun-bin remote latest would raise the ceiling, and ralph-tui would select a newer PV under hypothetical ceilings
- **THEN** stdout includes the hypothetical ralph-tui lane line and exactly one `dev-util/ralph-tui:` refuse line naming `dev-lang/bun-bin`
- **AND** those lines do not contain "blocked on"
- **AND** the program does not treat ralph-tui as having no outdated output solely because the on-disk plan matches local ebuilds

#### Scenario: Equal ceilings do not indicate blocked-on

- **WHEN** `outdated` checks `dev-util/ralph-tui` and bun-bin's remote latest yields hypothetical overlay ceilings equal to on-disk bun-bin ceilings
- **THEN** ralph-tui stdout does not contain "blocked on" and does not contain a provider-refuse line
- **AND** the program does not re-list ralph-tui upstream versions or re-probe per-PV metadata solely to evaluate plan-delta

#### Scenario: Provider latest failure does not look current

- **WHEN** `outdated` checks `dev-util/ralph-tui` and bun-bin's upstream latest cannot be fetched
- **THEN** the ralph-tui check emits an error-class report that names `dev-lang/bun-bin`
- **AND** stdout does not omit ralph-tui as an ordinary up-to-date package

#### Scenario: Outdated does not commit or build

- **WHEN** `outdated` includes bun-bin and ralph-tui and prints ralph-tui's hypothetical gap lines
- **THEN** the program does not create an overlay git commit
- **AND** the program does not start a materialize-image build

### Requirement: Outdated reports ebuild removals apply would perform

For each `DepsAndAssets` package, after the runtime-lane gap lines of the plan this check is displaying (the hypothetical working plan when `outdated-command` selects that plan, otherwise the on-disk plan), the program SHALL print one removal line per non-live PV that `update` of that package alone would delete. A PV is a removal candidate when it is a non-live local PV absent from that plan's unique PV set. The program SHALL omit a candidate that overlay-internal atom closure would keep because another on-disk ebuild still requires it, using on-disk ebuilds only and not a same-run plan of other packages. Each removal line SHALL have the form `category/package PV -> removed`, with `PV` in pretty form without a leading `v` and without a revision suffix. Multiple revisions of one PV SHALL produce one line. Removal lines SHALL NOT include a lane label or an assets marker. Removal lines SHALL follow the gap lines and SHALL precede a provider-refuse line when that line is emitted, in ascending PV order.

`GitMvAndManifest` packages SHALL NOT gain `-> removed` lines because older ebuilds remain beside the newest ebuild.

When the displayed plan has at least one removal candidate and the keep decision cannot be read or parsed, the program SHALL emit an error-class report for that package, SHALL NOT print a removal line for it, and SHALL still emit any lane gap lines and provider-refuse line that the displayed plan otherwise requires.

#### Scenario: Prune-only package prints a removal line

- **WHEN** a `DepsAndAssets` package's displayed plan selects only an installed PV and another non-live local PV is absent from that plan and no on-disk ebuild requires the absent PV
- **THEN** stdout includes `category/package PV -> removed` for the absent PV
- **AND** the program does not omit the package as current

#### Scenario: Pinned PV is not reported removed

- **WHEN** the displayed plan's unique set omits `6.6.1` and a remaining on-disk ebuild still requires that PV
- **THEN** stdout does not include a `6.6.1 -> removed` line for that package

#### Scenario: Removals follow gaps and precede the refuse line

- **WHEN** `outdated` checks a Bun consumer whose hypothetical plan has a lane gap and a removable local PV, and the provider is not in the check set so a refuse line is emitted
- **THEN** the lane gap line appears before the `PV -> removed` line
- **AND** the `PV -> removed` line appears before the `category/package:` refuse line

#### Scenario: Keep-set failure does not guess a removal

- **WHEN** the displayed plan has a removal candidate and the keep decision fails
- **THEN** the package check emits an error-class report
- **AND** stdout does not include a `-> removed` line for that package

#### Scenario: GitMv bun-bin does not use removal lines

- **WHEN** `outdated` checks `dev-lang/bun-bin` and the package directory still contains an older compile-pin ebuild beside the newest ebuild
- **THEN** stdout does not include a `dev-lang/bun-bin <PV> -> removed` line for that older ebuild
