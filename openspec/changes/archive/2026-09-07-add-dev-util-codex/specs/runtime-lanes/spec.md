## ADDED Requirements

### Requirement: Policy arch allowlist for lane participation

`DepsAndAssets` policy MAY restrict which runtime architectures participate in lane planning and KEYWORDS collapse. When an allowlist is set, the planner SHALL create lanes only for those arches (plain and tilde still follow the runtime package’s KEYWORDS on those arches). Arches outside the allowlist SHALL NOT receive lane targets, SHALL NOT appear in planned KEYWORDS, and SHALL NOT contribute ceilings to harvest-versus-ceiling checks. When no allowlist is set, all arches discovered on the runtime package remain in the lane set.

When an allowlist is set, planned KEYWORDS for each unique PV SHALL be `-*` plus the tilde tokens for allowlisted arches that have a target (`KEYWORDS="-* ~amd64"` when only amd64 is allowed and targeted). Packages without an allowlist SHALL NOT gain a `-*` token solely from this requirement.

Policy for `dev-util/codex` SHALL allowlist `amd64` only.

#### Scenario: Codex plans amd64 only

- **WHEN** `dev-util/codex` is planned and gentoo rust/rust-bin also keyword `arm64`
- **THEN** no arm64 lane target is produced
- **AND** planned KEYWORDS are `-* ~amd64` and do not include `~arm64`

#### Scenario: Harvest ceiling ignores non-allowlisted arches

- **WHEN** a Codex full-path unit’s harvest floor is below the amd64 rust ceiling and above some rust-bin arm64 ceiling
- **THEN** harvest-versus-ceiling does not hard-fail solely because of the arm64 ceiling

#### Scenario: hk still uses every rust arch

- **WHEN** `dev-util/hk` is planned
- **THEN** lane participation still includes every arch present on `dev-lang/rust` ∪ `dev-lang/rust-bin`
- **AND** planned KEYWORDS do not include `-*` solely from this requirement
