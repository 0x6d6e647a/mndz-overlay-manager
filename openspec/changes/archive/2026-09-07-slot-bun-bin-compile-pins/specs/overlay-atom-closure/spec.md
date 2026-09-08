## MODIFIED Requirements

### Requirement: Overlay-internal atoms come from ebuild DEPEND-family text

The program SHALL discover overlay-internal atoms by reading ebuild `DEPEND`, `RDEPEND`, `BDEPEND`, `PDEPEND`, and `IDEPEND` assignments (including same-file `${RDEPEND}` / `${BDEPEND}` / `${DEPEND}` expansion in assignment order). An atom is overlay-internal when its `category/package` matches an overlay package directory. Gentoo-only atoms (for example `sys-apps/ripgrep`, `dev-lang/go`) SHALL NOT be overlay-internal. The program SHALL NOT require a second per-package edge map. The program SHALL evaluate the ebuild **as it will exist in the commit** for the unit being written, and all other remaining non-live overlay ebuilds as they will exist after this run’s already-decided applies and prunes (selected packages: planned remaining tree; unselected packages: on-disk non-live ebuilds).

This parse SHALL NOT create overlay wait-edges as specified by `overlay-apply-waves`.

#### Scenario: hk usage atom is overlay-internal

- **WHEN** `dev-util/hk` `RDEPEND` contains `dev-util/usage` and `dev-util/usage` is an overlay package directory
- **THEN** that atom is overlay-internal

#### Scenario: opencode ripgrep is not overlay-internal

- **WHEN** `dev-util/opencode` `RDEPEND` contains `sys-apps/ripgrep` and that package is not an overlay package directory
- **THEN** that atom is not overlay-internal

#### Scenario: bun-bin BDEPEND is overlay-internal and not a Graph 1 edge from this parse

- **WHEN** `dev-util/ralph-tui` to-be-written `BDEPEND` contains `>=dev-lang/bun-bin-1.3.6:0`
- **THEN** atom closure treats bun-bin as a provider package
- **AND** the program does not create a technique wait-edge solely from that parse

### Requirement: Satisfiability is PV-only

An overlay-internal atom SHALL be satisfiable when at least one retained non-live provider ebuild’s PV matches the atom using unversioned (any PV), `>=`, `<=`, `>`, `<`, `=`, or `~` (same PV, any revision), compared with the overlay’s existing PV comparison. KEYWORDS visibility SHALL NOT be required. Subslots SHALL NOT be interpreted; a trailing `:=` on an atom SHALL NOT by itself make the atom unsatisfiable. An explicit slot other than omitted or `0` on an overlay-internal atom SHALL hard-fail the package whose ebuild contains it, **except** that `dev-lang/bun-bin` pin slots use `SLOT="${PV}"` on the **provider ebuild** (consumer atoms SHALL NOT name those pin slots). Self-atoms (consumer `category/package` naming itself) SHALL be ignored.

A bun-bin atom whose slot is omitted or `0` (including `>=dev-lang/bun-bin-<min>:0`) SHALL be satisfiable only by a retained non-live bun-bin ebuild whose `SLOT` is `0` (or omitted, treated as `0`) and whose PV matches the version operator. A bun-bin ebuild with `SLOT="${PV}"` other than `0` SHALL NOT satisfy a `:0` or unslotted bun-bin floor atom. An exact `=dev-lang/bun-bin-<PV>` atom SHALL be satisfiable by a retained ebuild of that PV regardless of SLOT.

#### Scenario: Unversioned usage matches any remaining usage PV

- **WHEN** hk `RDEPEND` contains unversioned `dev-util/usage` and overlay usage has non-live PV `6.6.1`
- **THEN** the atom is satisfiable

#### Scenario: Greater-or-equal bun-bin matches a newer PV

- **WHEN** ralph-tui `BDEPEND` contains `>=dev-lang/bun-bin-1.3.6:0` and overlay bun-bin has `1.4.2` with `SLOT="0"` and `1.3.14` with `SLOT="1.3.14"`
- **THEN** the atom is satisfiable via `1.4.2`

#### Scenario: Pin slot does not satisfy slot-zero floor

- **WHEN** ralph-tui `BDEPEND` contains `>=dev-lang/bun-bin-1.3.6:0` and overlay bun-bin has only `1.3.14` with `SLOT="1.3.14"`
- **THEN** the atom is not satisfiable

#### Scenario: Exact pin matches pin-slot PV

- **WHEN** a remaining opencode ebuild contains `=dev-lang/bun-bin-1.3.14` and overlay bun-bin has `1.3.14` with `SLOT="1.3.14"`
- **THEN** the atom is satisfiable

#### Scenario: Exact pin is unsatisfied after that PV is gone

- **WHEN** a retained hk ebuild contains `=dev-util/usage-6.6.1` and overlay usage has only `6.8.0`
- **THEN** the atom is not satisfiable

### Requirement: GitMv rename-away does not unsatisfy retained consumers

When `GitMvAndManifest` would rename the newest non-live provider ebuild from PV Old to PV New, the program SHALL hard-fail that unit without renaming if dropping Old would leave some planned-remaining consumer overlay-internal atom unsatisfied and no remaining sibling provider PV (including New, once renamed) would satisfy it. Other non-newest versions SHALL remain as already specified for GitMv.

For `dev-lang/bun-bin` only, when that unsatisfied atom is an exact compile pin `=dev-lang/bun-bin-Old`, the program SHALL NOT hard-fail: it SHALL add New and keep Old as specified by update-apply bun-bin GitMv add-latest. The program SHALL NOT copy Old aside as a new exact-set for GitMv packages other than bun-bin compile-pin keep.

#### Scenario: Rename newer still satisfies greater-or-equal

- **WHEN** bun-bin GitMv moves latest from `1.3.14` to `1.4.0` and ralph-tui `BDEPEND` is `>=dev-lang/bun-bin-1.3.6:0`
- **THEN** the rename-away guard does not fail solely for that atom
- **AND** latest is `SLOT="0"` after the move

#### Scenario: bun-bin exact pin is kept by adding latest

- **WHEN** bun-bin GitMv would move newest `1.3.14` to `1.4.2` and a remaining opencode ebuild contains `=dev-lang/bun-bin-1.3.14`
- **THEN** the unit does not hard-fail
- **AND** `1.3.14` remains on disk as a pin slot as specified by update-apply

#### Scenario: Rename away an exact pin hard-fails

- **WHEN** usage GitMv would rename the only ebuild `6.6.1` to `6.8.0` and a remaining hk ebuild contains `=dev-util/usage-6.6.1`
- **THEN** usage hard-fails without renaming
- **AND** `6.6.1` remains on disk
