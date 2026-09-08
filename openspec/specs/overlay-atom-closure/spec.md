# overlay-atom-closure Specification

## Purpose

Keep every signed overlay commit Portage-honest for overlay-internal dependency atoms: retained consumer ebuilds must be satisfiable by retained provider ebuilds, without using that parse as a runtime-lane ceiling wait-edge.

## Requirements

### Requirement: Overlay commits are closed under overlay-internal atoms

After every successful signed overlay commit produced by `update`, every retained non-live ebuild in an overlay package directory SHALL have every overlay-internal dependency atom (as specified below) satisfiable by some retained non-live provider ebuild still in the overlay tree. Live/`9999` ebuilds SHALL NOT count as retained consumers or as satisfying providers. The program SHALL NOT defer this check until the end of the `update` run: a mid-run HEAD that violates the invariant is a failed consumer (or provider) unit, not a later cleanup.

#### Scenario: Sequential commits each leave a closed tree

- **WHEN** untargeted `update` commits `dev-util/usage` and then commits `dev-util/hk`
- **THEN** HEAD after the usage commit is atom-closed
- **AND** HEAD after the hk commit is atom-closed

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

### Requirement: USE conditionals are required anyway

A dependency atom inside a USE-conditional block (`flag? ( … )`) SHALL still be treated as required for atom closure. Default-off IUSE SHALL NOT drop the atom.

#### Scenario: hk completion usage still counts

- **WHEN** hk `RDEPEND` contains `bash-completion? ( dev-util/usage )` and `IUSE` does not default-enable `bash-completion`
- **THEN** `dev-util/usage` is still an overlay-internal atom of that ebuild

### Requirement: Group and parse failure policy

For `|| ( … )` groups, if any alternative names an overlay package, at least one overlay-named alternative SHALL be satisfiable; groups that name only non-overlay packages SHALL be ignored for atom closure. Overlay-internal blockers (`!` / `!!`) SHALL hard-fail the package whose ebuild contains them. If the program cannot parse an ebuild’s DEPEND-family assignments far enough to extract `category/package` atoms, it SHALL hard-fail that package’s overlay write (fail-closed) without committing that unit.

#### Scenario: Gentoo rust or-group is ignored

- **WHEN** autolith `BDEPEND` contains `|| ( dev-lang/rust-bin dev-lang/rust )` and neither is an overlay package directory
- **THEN** atom closure ignores that group

#### Scenario: Unparseable consumer ebuild fails closed

- **WHEN** a selected package’s to-be-written ebuild DEPEND-family text cannot be parsed for cat/pkg atoms
- **THEN** that package hard-fails without a signed overlay commit for that unit

### Requirement: Forward wait or refuse at overlay write

Before overlay mutation (ebuild rewrite or GitMv rename, Manifest, egencache, signed commit) of a selected package C, the program SHALL evaluate C’s to-be-written ebuild against the overlay tree as it will be after providers that must land first have committed. If every overlay-internal atom is already satisfiable by the current retained provider ebuilds, C MAY proceed. If an atom on provider P is unsatisfied:

- When P is in this `update` selection and P’s **planned remaining** non-live PVs would satisfy the atom, the program SHALL wait until P has a terminal overlay outcome that is not a hard-fail (signed overlay commit, or a no-work / soft-skip plan result), then re-check the tree and proceed only if the atom is satisfiable.
- Otherwise the program SHALL hard-fail C without overlay mutation. The error SHALL name C, P, and the atom, and SHALL NOT add P to the selection. Recovery SHALL mention updating P or running untargeted `update`.

The program SHALL NOT use hypothetical runtime-lane ceilings or plan-delta for this decision. Other selected packages SHALL continue.

Waiting for P SHALL happen **before** entering the overlay `egencache` / `git add` / `git commit` critical section. The program SHALL NOT wait while holding that critical section. Language materialize and assets publish for C MAY overlap P.

If P hard-fails while C is waiting, C SHALL hard-fail naming P and SHALL NOT overlay-mutate. If waiting would require a cycle of overlay-internal atom waits (C needs P’s planned PV and P needs C’s), the program SHALL hard-fail the involved packages with an error that names the cycle.

#### Scenario: Untargeted update commits usage before hk overlay write

- **WHEN** untargeted `update` selects usage and hk, usage needs work, and hk’s to-be-written ebuild has an overlay-internal atom that current usage PVs do not satisfy but usage’s planned remaining PVs would satisfy
- **THEN** hk does not overlay-mutate until usage has a signed overlay commit
- **AND** hk language materialize MAY run while usage applies

#### Scenario: Targeted hk refuses when usage cannot satisfy

- **WHEN** the user runs `update dev-util/hk`, usage is not selected, and hk’s to-be-written ebuild has an overlay-internal usage atom that overlay usage PVs do not satisfy
- **THEN** hk hard-fails naming `dev-util/usage` and the atom
- **AND** the run does not apply `dev-util/usage`

#### Scenario: Unversioned usage does not wait

- **WHEN** untargeted `update` selects usage and hk, hk’s to-be-written ebuild has unversioned `dev-util/usage`, and overlay already has some non-live usage PV
- **THEN** hk overlay write is not withheld solely because usage also needs work

#### Scenario: Wait does not hold the overlay commit lock

- **WHEN** hk is waiting for usage’s signed overlay commit
- **THEN** usage can still enter the overlay critical section
- **AND** hk is not inside that critical section while waiting

### Requirement: Reverse-dep keep on DepsAndAssets prune

When `DepsAndAssets` prune runs after a successful planned-PV apply for provider P, the program SHALL retain every non-live P PV that is either in P’s runtime-lane unique planned set or still required to satisfy overlay-internal atoms on **planned remaining** consumer ebuilds (selected consumers: their planned remaining trees; unselected consumers: on-disk non-live ebuilds). The program SHALL remove other non-live P ebuilds not in that keep-set, matching `runtime-lanes` failure isolation (do not prune if a planned target failed and pruning would drop a tip without its replacement). Reverse-dep keep SHALL NOT add a PV that is not already a non-live ebuild on disk.

#### Scenario: Exact pin keeps an extra usage PV

- **WHEN** usage’s runtime-lane plan unique set is `{6.8.0}`, overlay also has `6.6.1`, and a planned-remaining hk ebuild contains `=dev-util/usage-6.6.1`
- **THEN** after usage apply both `6.6.1` and `6.8.0` remain
- **AND** the program does not delete `6.6.1`

#### Scenario: Unversioned atom does not keep extras

- **WHEN** usage’s unique planned set is `{6.8.0}`, overlay also has `6.6.1`, and remaining hk/mise ebuilds name unversioned `dev-util/usage`
- **THEN** after successful usage apply `6.6.1` may be pruned
- **AND** `6.8.0` remains

#### Scenario: Keep uses planned remaining consumers

- **WHEN** hk is selected and will prune an old hk PV that was the only ebuild naming `=dev-util/usage-6.6.1`, and usage’s lane plan is `{6.8.0}`
- **THEN** usage prune is not required to keep `6.6.1` solely because the pre-run hk tree still had that pin

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
